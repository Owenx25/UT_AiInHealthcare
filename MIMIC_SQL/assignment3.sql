-- 1) What does the data for unsuccessful callouts look like?

SET search_path = mimiciii;

WITH careunit_mapping AS (
    SELECT 'TSICU' AS careunit, 'Trauma Surgical Intensive Care Unit' AS careunit_name UNION ALL
    SELECT 'CSRU', 'Cardiac Surgery Recovery Unit' UNION ALL
    SELECT 'MICU', 'Medical Intensive Care Unit' UNION ALL
    SELECT 'SICU', 'Surgical Intensive Care Unit' UNION ALL
    SELECT 'CCU', 'Coronary Care Unit'
)

SELECT 
    COALESCE(c1.careunit_name, 'Unknown') AS submitted_careunit,
    COALESCE(c2.careunit_name, 'Unknown') AS current_careunit,
	CASE 
		WHEN CALLOUT_WARDID = 1 THEN 'First available ward'
		ELSE 'other ward'
	END as callout_ward,
    COUNT(*) AS count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 2) AS percentage
FROM mimiciii.callout
LEFT JOIN careunit_mapping c1 ON callout.submit_careunit = c1.careunit
LEFT JOIN careunit_mapping c2 ON callout.curr_careunit = c2.careunit
WHERE NOT callout_outcome = 'Discharged'
GROUP BY submit_careunit, curr_careunit, c1.careunit_name, c2.careunit_name, CALLOUT_WARDID
ORDER BY percentage DESC;

-- 2) of the cancelled callouts in the largest group (MICU -> First available ward),
--    What do the transfers for individual patients look like
SELECT 
	t.hadm_id,
	t.subject_id,
	COUNT(t.hadm_id) as num_transfers,
	(AVG(t.los) / 24)::NUMERIC(10, 2) as average_length_of_stay_days
FROM mimiciii.transfers t
INNER JOIN mimiciii.callout c ON c.hadm_id=t.hadm_id
WHERE 
	NOT c.callout_outcome = 'Discharged' AND
	c.curr_careunit = 'MICU' AND
	c.submit_careunit = 'MICU' AND
	c.CALLOUT_WARDID = 1
GROUP BY t.hadm_id, t.subject_id
ORDER BY num_transfers DESC;


-- 3) One patient (122457) in 2) had 34(!) transfers, what is the history of this patient's charts?
--    What items deviated a lot?

SELECT itm.label, charts.item_count, charts.max_reading, charts.min_reading, charts.avg_reading, charts.median_value FROM (
	SELECT 
		ch.itemid,
		COUNT(ch.itemid) as item_count,
		MAX(ch.valuenum) as max_reading,
		MIN(ch.valuenum) as min_reading,
		AVG(ch.valuenum)::NUMERIC(10,2) as avg_reading,
		STDDEV_SAMP(ch.valuenum) as std,
		PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ch.valuenum) AS median_value
	FROM chartevents ch
	WHERE ch.hadm_id=122457 AND
	ch.valuenum IS NOT NULL
	GROUP BY ch.itemid
	) as charts
INNER JOIN d_items itm ON charts.itemid = itm.itemid
WHERE charts.std > 2
ORDER BY item_count DESC

-- 4) What kind of other patients had such deviations in respiratory rate

WITH high_variance_admissions AS (
    -- Step 1: Identify admissions with stddev of respiratory rate > 2
    SELECT ch.hadm_id, 
           pat.gender, 
           adm.ethnicity,
           EXTRACT(YEAR FROM adm.admittime) - EXTRACT(YEAR FROM pat.dob) AS age, 
           STDDEV_SAMP(ch.valuenum) AS respiratory_rate_stddev
    FROM chartevents ch
    INNER JOIN d_items itm ON itm.itemid = ch.itemid
    INNER JOIN admissions adm ON adm.hadm_id = ch.hadm_id
    INNER JOIN patients pat ON pat.subject_id = adm.subject_id
    WHERE itm.label = 'Respiratory Rate'  -- Only select respiratory rate readings
    AND ch.valuenum IS NOT NULL           -- Exclude NULL values
    GROUP BY ch.hadm_id, pat.gender, adm.ethnicity, pat.dob, adm.admittime
    HAVING STDDEV_SAMP(ch.valuenum) > 2
)
-- Step 2: Aggregate by gender, age group, and ethnicity, then rank by frequency
SELECT gender, 
       FLOOR(age / 10) * 10 AS age_group,  -- Convert age into 10-year groups (e.g., 20-29, 30-39)
       ethnicity, 
       COUNT(*) AS admission_count
FROM high_variance_admissions
GROUP BY gender, age_group, ethnicity
ORDER BY admission_count DESC
LIMIT 10;

-- 5) White men in their 60s seem to disproportionately struggle with respiratory issues 
--    (not COVID related). What are the common diagnosis for this group that relate to respiratory issues? 

WITH patient_subset AS (
    -- Step 1: Identify White men aged 60-69 at admission
    SELECT pat.subject_id, adm.hadm_id
    FROM patients pat
    INNER JOIN admissions adm ON pat.subject_id = adm.subject_id
    WHERE pat.gender = 'M'
    AND adm.ethnicity LIKE 'WHITE%'  -- Ensures we capture variations (e.g., "White - Not Hispanic")
    AND EXTRACT(YEAR FROM adm.admittime) - EXTRACT(YEAR FROM pat.dob) BETWEEN 60 AND 69
)

-- Step 2: Get diagnoses for these patients and count occurrences
SELECT d_icd.long_title AS diagnosis, 
       COUNT(*) AS diagnosis_count,
	   ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 2) AS percentage
FROM patient_subset p
INNER JOIN diagnoses_icd diag ON p.hadm_id = diag.hadm_id
INNER JOIN d_icd_diagnoses d_icd ON diag.icd9_code = d_icd.icd9_code
GROUP BY d_icd.long_title
ORDER BY diagnosis_count DESC
LIMIT 20;

-- 6) Of the repiratory related conditions, what is some information about stays?
--    (ex. avg length of stay, precentage of stays resulting in death)

WITH patient_subset AS (
    -- Step 1: Identify White men aged 60-69 at admission
    SELECT pat.subject_id, adm.hadm_id
    FROM patients pat
    INNER JOIN admissions adm ON pat.subject_id = adm.subject_id
    WHERE pat.gender = 'M'
    AND adm.ethnicity LIKE 'WHITE%'  -- Ensures we capture variations (e.g., "White - Not Hispanic")
    AND EXTRACT(YEAR FROM adm.admittime) - EXTRACT(YEAR FROM pat.dob) BETWEEN 60 AND 69
)

SELECT 
	d_icd.long_title, 
	COUNT(*) as diagnosis_count,
	AVG(adm.dischtime - adm.admittime) as avg_los,
	(SUM(
		CASE 
			WHEN adm.deathtime IS NOT NULL THEN 1 
			ELSE 0 
		END
	)::NUMERIC / COUNT(*))::NUMERIC(10, 2) AS percent_deaths
FROM patient_subset sub
INNER JOIN diagnoses_icd diag ON sub.hadm_id = diag.hadm_id
INNER JOIN d_icd_diagnoses d_icd ON d_icd.icd9_code = diag.icd9_code
INNER JOIN admissions adm ON sub.hadm_id=adm.hadm_id
WHERE d_icd.long_title = ANY(ARRAY[
		'Esophageal reflux',
		'Acute respiratory failure',
		'Chronic airway obstruction, not elsewhere classified',
		'Tobacco use disorder',
		'Pneumonia, organism unspecified'
	])
GROUP BY d_icd.long_title
ORDER BY diagnosis_count DESC

-- 7) What were common prescriptions for the patient subset with each related respiratory diagnosis

WITH patient_subset AS (
    -- Step 1: Identify White men aged 60-69 at admission
    SELECT pat.subject_id, adm.hadm_id
    FROM patients pat
    INNER JOIN admissions adm ON pat.subject_id = adm.subject_id
    WHERE pat.gender = 'M'
    AND adm.ethnicity LIKE 'WHITE%'  -- Ensures we capture variations (e.g., "White - Not Hispanic")
    AND EXTRACT(YEAR FROM adm.admittime) - EXTRACT(YEAR FROM pat.dob) BETWEEN 60 AND 69
),
ranked_drugs AS (
    SELECT 
        d_icd.long_title,
        p.drug,
        COUNT(*) AS prescription_count,
        RANK() OVER (PARTITION BY d_icd.long_title ORDER BY COUNT(*) DESC) AS drug_rank
    FROM patient_subset sub
    INNER JOIN diagnoses_icd diag ON sub.hadm_id = diag.hadm_id
    INNER JOIN d_icd_diagnoses d_icd ON d_icd.icd9_code = diag.icd9_code
    INNER JOIN prescriptions p ON sub.hadm_id = p.hadm_id
    WHERE d_icd.long_title IN (
        'Esophageal reflux',
        'Acute respiratory failure',
        'Chronic airway obstruction, not elsewhere classified',
        'Tobacco use disorder',
		'Pneumonia, organism unspecified'
    )
    GROUP BY d_icd.long_title, p.drug
)
SELECT long_title, drug, prescription_count, drug_rank
FROM ranked_drugs
WHERE drug_rank <= 10
ORDER BY long_title ASC, prescription_count DESC;


-- 8) What sort of procedures are done on this subset

WITH patient_subset AS (
    -- Step 1: Identify White men aged 60-69 at admission
    SELECT pat.subject_id, adm.hadm_id
    FROM patients pat
    INNER JOIN admissions adm ON pat.subject_id = adm.subject_id
    WHERE pat.gender = 'M'
    AND adm.ethnicity LIKE 'WHITE%'  -- Ensures we capture variations (e.g., "White - Not Hispanic")
    AND EXTRACT(YEAR FROM adm.admittime) - EXTRACT(YEAR FROM pat.dob) BETWEEN 60 AND 69
),
diagnosed_patients AS (
    -- Step 2: Filter for Patients with Specific Diagnoses
    SELECT DISTINCT sub.subject_id, sub.hadm_id
    FROM patient_subset sub
    INNER JOIN diagnoses_icd diag ON sub.hadm_id = diag.hadm_id
    INNER JOIN d_icd_diagnoses d_icd ON d_icd.icd9_code = diag.icd9_code
    WHERE d_icd.long_title IN (
        'Esophageal reflux',
        'Acute respiratory failure',
        'Chronic airway obstruction, not elsewhere classified',
        'Tobacco use disorder'
    )
)
-- Step 3: Get Most Common Procedures for These Patients
SELECT proc.icd9_code, d_icd.long_title AS procedure_name, COUNT(*) AS procedure_count
FROM diagnosed_patients sub
INNER JOIN procedures_icd proc ON sub.hadm_id = proc.hadm_id
INNER JOIN d_icd_procedures d_icd ON proc.icd9_code = d_icd.icd9_code
GROUP BY proc.icd9_code, d_icd.long_title
ORDER BY procedure_count DESC
LIMIT 20;

-- 9) What diagnosis resulted in the highest percentage of death? -> A respiratory failure!
WITH diagnosis_death_stats AS (
    -- Step 1: Count total cases and deaths per diagnosis
    SELECT 
        d_icd.long_title AS diagnosis,
        COUNT(*) AS total_cases,
        SUM(CASE WHEN adm.deathtime IS NOT NULL THEN 1 ELSE 0 END) AS death_count,
        ROUND(100.0 * SUM(CASE WHEN adm.deathtime IS NOT NULL THEN 1 ELSE 0 END) / COUNT(*), 2) AS death_percentage
    FROM diagnoses_icd diag
    INNER JOIN d_icd_diagnoses d_icd ON diag.icd9_code = d_icd.icd9_code
    INNER JOIN admissions adm ON diag.hadm_id = adm.hadm_id
    GROUP BY d_icd.long_title
)
-- Step 2: Rank diagnoses by deaths and percentage
SELECT * 
FROM diagnosis_death_stats
ORDER BY death_count DESC, death_percentage DESC
LIMIT 10;  -- Get the top 10 diagnoses

-- 10) Which of these respiratory deaths had successful callouts?
WITH respiratory_cases AS (
    -- Step 1: Identify respiratory-related cases
    SELECT adm.hadm_id, d_icd.long_title AS diagnosis
    FROM diagnoses_icd diag
    INNER JOIN d_icd_diagnoses d_icd ON diag.icd9_code = d_icd.icd9_code
    INNER JOIN admissions adm ON diag.hadm_id = adm.hadm_id
    WHERE d_icd.long_title IN (
        'Esophageal reflux',
        'Acute respiratory failure',
        'Chronic airway obstruction, not elsewhere classified',
        'Tobacco use disorder'
    )
),
callout_stats AS (
    -- Step 2: Count total callouts and 'Discharged' callouts per diagnosis
    SELECT rc.diagnosis,
           COUNT(c.hadm_id) AS total_callouts,
           SUM(CASE WHEN c.callout_outcome = 'Discharged' THEN 1 ELSE 0 END) AS discharged_callouts
    FROM respiratory_cases rc
    INNER JOIN callout c ON rc.hadm_id = c.hadm_id
    GROUP BY rc.diagnosis
)
-- Step 3: Calculate percentage of 'Discharged' callouts
SELECT diagnosis,
       total_callouts,
       discharged_callouts,
       ROUND(100.0 * discharged_callouts / NULLIF(total_callouts, 0), 2) AS discharge_percentage
FROM callout_stats
ORDER BY discharge_percentage DESC;

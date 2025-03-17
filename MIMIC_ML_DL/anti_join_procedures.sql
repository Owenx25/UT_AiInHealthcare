SELECT a.* FROM mimiciii.admissions a
LEFT JOIN mimiciii.procedures_icd p ON a.hadm_id=p.hadm_id
WHERE 
	p.hadm_id IS NULL AND
	a.admission_type NOT IN ('NEWBORN') AND
	discharge_location NOT IN ('DEAD/EXPIRED')
ORDER BY a.discharge_location
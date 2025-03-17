SELECT 
    dp.long_title AS procedure_name,
    p.icd9_code AS procedure_code,
    COUNT(*) AS procedure_count
FROM mimiciii.PROCEDURES_ICD p
JOIN mimiciii.D_ICD_PROCEDURES dp 
    ON p.icd9_code = dp.icd9_code
GROUP BY dp.long_title, p.icd9_code
ORDER BY procedure_count DESC
LIMIT 100;
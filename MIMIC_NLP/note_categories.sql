SELECT DISTINCT category, COUNT(category) as ct
FROM mimiciii.noteevents
GROUP BY category
ORDER BY ct desc;
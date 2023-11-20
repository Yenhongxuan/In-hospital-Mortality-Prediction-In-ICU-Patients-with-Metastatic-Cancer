WITH dx AS -- sub-query diagnosed information about all admitted patient
(
  SELECT subject_id AS subject_id, hadm_id AS hadm_id, icd_version AS icd_version, TRIM(icd_code) AS icd_code
  FROM `physionet-data.mimiciv_hosp.diagnoses_icd`
), icd9 AS -- check whether type of patient's sick based on icd-9
(
  SELECT dx.subject_id AS subject_id
  , MAX(case when dx.icd_code in ('1960', '1961', '1962', '1963', '1965', '1966', '1968', '1969', '1970', '1971', '1972', '1973', '1974', '1975', '1976', '1977', '1978', '1980'
  , '1981', '1982', '1983', '1984', '1985', '1986', '1987', '19882', '19889', '1990') then 1 else 0 end) AS advanced_cancer
  , MAX(case when dx.icd_code in ('200', '201', '202', '203', '204', '205', '206', '207', '208') then 1
             when dx.icd_code LIKE '200%' then 1
             else 0 end) AS hematologic_malignancy
  FROM dx
  WHERE dx.icd_version = 9
  GROUP BY dx.subject_id
), icd10 AS -- check whether type of patient's sick based on icd-10
(
  SELECT dx.subject_id AS subject_id
  , MAX(case when dx.icd_code in ('C770', 'C771', 'C772', 'C773', 'C774', 'C775', 'C778', 'C779', 'C780', 'C7800', 'C7801', 'C7802', 'C781', 'C782', 'C783', 'C7830'
  , 'C7839', 'C784', 'C785', 'C786', 'C787', 'C788', 'C7880', 'C7889', 'C790', 'C7900', 'C7901','C7902', 'C791', 'C7910', 'C7911', 'C7919', 'C792', 'C793', 'C7931'
  , 'C7932', 'C794', 'C7940', 'C7949', 'C795', 'C7951', 'C7952', 'C796', 'C7960', 'C7961', 'C7962', 'C7963', 'C797', 'C7970', 'C7971', 'C7972', 'C798', 'C7981', 'C7982'
  , 'C7989', 'C799', 'C800' ) then 1 else 0 end) AS advanced_cancer
  , MAX(case when dx.icd_code in ('C81', 'C82', 'C83', 'C84', 'C85', 'C86', 'C88', 'C90', 'C91', 'C92', 'C93', 'C94', 'C95', 'C96') then 1
             when dx.icd_code LIKE 'C81%' then 1
             else 0 end) AS hematologic_malignancy
  FROM dx
  WHERE dx.icd_version = 10
  GROUP BY dx.subject_id
), icd_9_10 AS --Get index of metastatic cancer for each icu patient
(
  SELECT 
    icu_stays.subject_id AS subject_id, icu_stays.hadm_id AS hadm_id, icu_stays.stay_id AS stay_id, icu_stays.intime AS intime
    , GREATEST(COALESCE(icd9.advanced_cancer, 0), COALESCE(icd10.advanced_cancer, 0)) AS advanced_cancer
    , GREATEST(COALESCE(icd9.hematologic_malignancy, 0), COALESCE(icd10.hematologic_malignancy, 0)) AS hematologic_malignancy
  FROM `physionet-data.mimiciv_icu.icustays` AS icu_stays
  LEFT JOIN icd9 ON icu_stays.subject_id = icd9.subject_id
  LEFT JOIN icd10 ON icu_stays.subject_id = icd10.subject_id
), inclusion_set AS --Pick patient of metastatic cancer and age between 18 and 89, and return subject_id, hadm_id, stay_id, and intime of ICU
(
  SELECT i_9_10.subject_id AS subject_id, i_9_10.hadm_id AS hadm_id, i_9_10.stay_id AS stay_id, i_9_10.intime AS intime
  FROM icd_9_10 AS i_9_10
  INNER JOIN `physionet-data.mimiciv_hosp.patients` AS patients ON i_9_10.subject_id = patients.subject_id
  WHERE patients.anchor_age >= 18 
  AND patients.anchor_age <= 89
  AND (i_9_10.advanced_cancer = 1 OR i_9_10.hematologic_malignancy = 1)
  ORDER BY i_9_10.subject_id, i_9_10.intime
), baseline_level_1 AS 
(
  SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, Age.age AS Age, 
  icu_details.gender, admission.insurance AS insurance, admission.race AS race, admission.admission_type AS admission_type
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.age` AS Age 
  ON i_set.subject_id = Age.subject_id AND i_set.hadm_id = Age.hadm_id
  LEFT JOIN `physionet-data.mimiciv_derived.icustay_detail` AS icu_details 
  ON i_set.stay_id = icu_details.stay_id
  LEFT JOIN `physionet-data.mimiciv_hosp.admissions` AS admission
  ON i_set.hadm_id = admission.hadm_id
), baseline_level_2 AS
(
  SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
  lods.LODS AS lods, oasis.oasis AS oasis, sapsii.sapsii AS sapsii, sirs.sirs AS sirs, sepsis3.sepsis3 AS sepsis3, meld.meld AS meld
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.lods` AS lods
  ON i_set.stay_id = lods.stay_id
  LEFT JOIN `physionet-data.mimiciv_derived.oasis` AS oasis
  ON i_set.stay_id = oasis.stay_id
  LEFT JOIN `physionet-data.mimiciv_derived.sapsii` AS sapsii
  ON i_set.stay_id = sapsii.stay_id
  LEFT JOIN `physionet-data.mimiciv_derived.sirs` AS sirs
  ON i_set.stay_id = sirs.stay_id
  LEFT JOIN `physionet-data.mimiciv_derived.sepsis3` AS sepsis3
  ON i_set.stay_id = sepsis3.stay_id
  LEFT JOIN `physionet-data.mimiciv_derived.meld` AS meld
  ON i_set.stay_id = meld.stay_id
),

crrt_data AS(
  SELECT DISTINCT i_set.subject_id, i_set.stay_id,
  DATETIME_DIFF(CRRT.charttime, i_set.intime, DAY) AS crrt_day

  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.crrt` AS CRRT
  ON i_set.stay_id = CRRT.stay_id
),


invasive_line_data as(
  SELECT DISTINCT i_set.subject_id, i_set.stay_id, (case when InvasiveLine.starttime is not null then 1 else 0 end) as invasive_line_label
  -- , InvasiveLine.starttime, i_set.intime
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.invasive_line` AS InvasiveLine
  ON i_set.stay_id = InvasiveLine.stay_id
),

rrt_data AS(
  SELECT DISTINCT i_set.subject_id, i_set.stay_id,
  DATETIME_DIFF(RRT.charttime, i_set.intime, DAY) AS rrt_day

  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.rrt` AS RRT
  ON i_set.stay_id = RRT.stay_id
),

ventilation_data as(
  SELECT DISTINCT i_set.subject_id, i_set.stay_id, (case when Ventilation.starttime is not null then 1 else 0 end) as ventilation_label
  -- , InvasiveLine.starttime, i_set.intime
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.ventilation` AS Ventilation
  ON i_set.stay_id = Ventilation.stay_id
),

sedative_data as(
  with include_sedative as(
    SELECT subject_id, stay_id, hadm_id, starttime, endtime, itemid
    FROM `physionet-data.mimiciv_icu.inputevents`
    WHERE itemid IN (221668, 225942, 225972, 221744, 222168)
  )
  SELECT DISTINCT i_set.subject_id, i_set.stay_id, (case when include_sedative.starttime is not null then 1 else 0 end) as sedative_label
  FROM inclusion_set AS i_set
  LEFT JOIN include_sedative
  ON i_set.stay_id = include_sedative.stay_id and i_set.subject_id = include_sedative.subject_id
),

antibiotic_data as(
  SELECT DISTINCT i_set.subject_id, i_set.stay_id, (case when Antibiotic.starttime is not null then 1 else 0 end) as antibiotic_label
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.antibiotic` as Antibiotic
  ON i_set.stay_id = Antibiotic.stay_id and i_set.subject_id = Antibiotic.subject_id
),

vasoactive_data as(
  with norepinephrine_equivalent_dose as(
    SELECT DISTINCT stay_id, (case when norepinephrine_equivalent_dose is not null then 1 else 0 end) as norepinephrine_equivalent_dose_label
    FROM `physionet-data.mimiciv_derived.norepinephrine_equivalent_dose`
  )

  SELECT DISTINCT i_set.subject_id, i_set.stay_id, 
  (case when dobutamine is not null then 1 else 0 end) as dobutamine_label,
  (case when dopamine is not null then 1 else 0 end) as dopamine_label,
  (case when epinephrine is not null then 1 else 0 end) as epinephrine_label,
  (case when milrinone is not null then 1 else 0 end) as milrinone_label,
  (case when norepinephrine is not null then 1 else 0 end) as norepinephrine_label,
  (case when norepinephrine_equivalent_dose is not null then 1 else 0 end) as norepinephrine_equivalent_dose_label,
  (case when phenylephrine is not null then 1 else 0 end) as phenylephrine_label,
  (case when vasopressin is not null then 1 else 0 end) as vasopressin_label
  

  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.vasoactive_agent` as Vasoactive
  ON i_set.stay_id = Vasoactive.stay_id 
  LEFT JOIN physionet-data.mimiciv_derived.norepinephrine_equivalent_dose as Norepinephrine_equivalent_dose
  ON i_set.stay_id = Norepinephrine_equivalent_dose.stay_id 
)

-- SELECT COUNT (DISTINCT subject_id)
SELECT *
FROM vasoactive_data
  



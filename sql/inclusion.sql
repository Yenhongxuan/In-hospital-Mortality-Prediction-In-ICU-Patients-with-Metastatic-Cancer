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
    icu_stays.subject_id AS subject_id, icu_stays.hadm_id AS hadm_id, icu_stays.stay_id AS stay_id, 
    icu_stays.icu_intime AS intime, icu_stays.icu_outtime AS outtime, icu_stays,dischtime AS dischtime, icu_stays.dod AS dod, icu_stays.hospital_expire_flag AS label_hosp
    , GREATEST(COALESCE(icd9.advanced_cancer, 0), COALESCE(icd10.advanced_cancer, 0)) AS advanced_cancer
    , GREATEST(COALESCE(icd9.hematologic_malignancy, 0), COALESCE(icd10.hematologic_malignancy, 0)) AS hematologic_malignancy, 
    CASE
      WHEN icu_stays.dod < icu_stays.icu_outtime THEN 1
      ELSE 0
    END AS label_icu
  FROM `physionet-data.mimiciv_derived.icustay_detail` AS icu_stays
  LEFT JOIN icd9 ON icu_stays.subject_id = icd9.subject_id
  LEFT JOIN icd10 ON icu_stays.subject_id = icd10.subject_id
), inclusion_set AS --Pick patient of metastatic cancer and age between 18 and 89, and return subject_id, hadm_id, stay_id, and intime of ICU
(
  SELECT i_9_10.subject_id AS subject_id, i_9_10.hadm_id AS hadm_id, i_9_10.stay_id AS stay_id, i_9_10.intime AS intime, i_9_10.outtime AS outtime, i_9_10.dischtime AS dischtime,
  i_9_10.dod AS dod, i_9_10.label_hosp AS label_hosp, i_9_10.label_icu AS label_icu, 
  DATETIME_DIFF(i_9_10.outtime, i_9_10.intime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_9_10.dischtime, i_9_10.intime, HOUR) AS hosp_timestep_back
  FROM icd_9_10 AS i_9_10
  INNER JOIN `physionet-data.mimiciv_hosp.patients` AS patients ON i_9_10.subject_id = patients.subject_id
  WHERE patients.anchor_age >= 18 
  AND patients.anchor_age <= 89
  AND (i_9_10.advanced_cancer = 1 OR i_9_10.hematologic_malignancy = 1)
  ORDER BY i_9_10.subject_id, i_9_10.intime
), baseline_level_1 AS 
(
  SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, Age.age AS Age, icu_details.gender,
  CASE
    WHEN admission.insurance LIKE 'Government%' THEN 1
    WHEN admission.insurance LIKE 'Medicaid%' THEN 2
    WHEN admission.insurance LIKE 'Medicare%' THEN 3
    WHEN admission.insurance LIKE 'Private%' THEN 4
    WHEN admission.insurance LIKE 'Salf-pay' THEN 5
    ELSE 6
  END AS insurance, 
  CASE
    WHEN admission.race LIKE 'WHITE%' THEN 4
    WHEN admission.race LIKE 'ASIAN%' THEN 3
    WHEN admission.race LIKE 'UNABLE TO OBTAIN%' THEN 5
    WHEN admission.race LIKE 'BLACK%' THEN 6
    WHEN admission.race LIKE 'AMERICAN%' THEN 7
    WHEN admission.race LIKE 'HISPANIC%' THEN 8
    WHEN admission.race LIKE 'UNKNOWN%' THEN 1
    ELSE 2
  END AS race, 
  CASE
    WHEN admission.admission_type LIKE 'AMBULATORY OBSERVATION%' THEN 1
    WHEN admission.admission_type LIKE 'DIRECT EMER%' THEN 2
    WHEN admission.admission_type LIKE 'DIRECT OBSERVATION%' THEN 3
    WHEN admission.admission_type LIKE 'ELECTIVE%' THEN 4
    WHEN admission.admission_type LIKE 'EU OBSERVATION%' THEN 5
    WHEN admission.admission_type LIKE 'EW EMER%' THEN 6
    WHEN admission.admission_type LIKE 'OBSERVATION ADMIT%' THEN 7
    WHEN admission.admission_type LIKE 'SURGICAL SAME DAY ADMISSION%' THEN 8
    WHEN admission.admission_type LIKE 'URGENT%' THEN 9
  END AS admission_type
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
  lods.LODS AS lods, oasis.oasis AS oasis, sapsii.sapsii AS sapsii, sirs.sirs AS sirs, 
  CASE 
    WHEN sepsis3.sepsis3 IS NOT NULL THEN sepsis3.sepsis3
    ELSE FALSE
  END AS sepsis3, meld.meld AS meld
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
), Heart_Rate AS
(
  With Heart_Rate_part AS   
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime, d_items.label AS label
    FROM inclusion_set AS i_set
    LEFT JOIN `physionet-data.mimiciv_icu.chartevents` AS chartevents
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 220045
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  ), Heart_Rate_raw AS   
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, i_set.outtime AS outtime, i_set.dod AS dod, h_p.value AS value, h_p.charttime AS charttime, 
     DATETIME_DIFF(h_p.charttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, h_p.charttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, h_p.charttime, HOUR) AS hosp_timestep_back, RANK() OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(h_p.charttime, i_set.intime, HOUR) ORDER BY h_p.charttime ASC) AS icu_timestep_rank, i_set.label_hosp AS label_hosp, i_set.label_icu AS label_icu
    FROM inclusion_set AS i_set
    LEFT JOIN Heart_Rate_part AS h_p
    ON i_set.subject_id = h_p.subject_id AND i_set.hadm_id = h_p.hadm_id AND i_set.stay_id = h_p.stay_id
  )
  SELECT *
  FROM Heart_Rate_raw
  WHERE Heart_Rate_raw.icu_timestep_rank = 1
  ORDER BY Heart_Rate_raw.stay_id, Heart_Rate_raw.charttime

),Arterial_blood_pressure_sbp AS
(
  WITH Arterial_blood_pressure_part AS
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime
    FROM inclusion_set AS i_set
    LEFT Join `physionet-data.mimiciv_icu.chartevents` AS chartevents 
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items 
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 220050
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  ), Arterial_blood_pressure_raw AS    
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, i_set.outtime, i_set.dod, n_p.value AS value, n_p.charttime AS charttime, 
    DATETIME_DIFF(n_p.charttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, n_p.charttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, n_p.charttime, HOUR) AS hosp_timestep_back, DATETIME_DIFF(i_set.dod, n_p.charttime, HOUR) AS death_timestep, RANK() OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(n_p.charttime, i_set.intime, HOUR) ORDER BY n_p.charttime ASC) AS icu_timestep_rank

    FROM inclusion_set AS i_set
    LEFT JOIN Arterial_blood_pressure_part AS n_p
    ON i_set.subject_id = n_p.subject_id AND i_set.hadm_id = n_p.hadm_id AND i_set.stay_id = n_p.stay_id
  )
  SELECT *
  FROM Arterial_blood_pressure_raw
  WHERE Arterial_blood_pressure_raw.icu_timestep_rank = 1
  ORDER BY Arterial_blood_pressure_raw.stay_id, Arterial_blood_pressure_raw.charttime
  
), 
Arterial_blood_pressure_dbp AS
(
  WITH Arterial_blood_pressure_part AS
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime
    FROM inclusion_set AS i_set
    LEFT Join `physionet-data.mimiciv_icu.chartevents` AS chartevents 
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items 
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 220051
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  ), Arterial_blood_pressure_raw AS    
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, i_set.outtime, i_set.dod, n_p.value AS value, n_p.charttime AS charttime, 
    DATETIME_DIFF(n_p.charttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, n_p.charttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, n_p.charttime, HOUR) AS hosp_timestep_back, DATETIME_DIFF(i_set.dod, n_p.charttime, HOUR) AS death_timestep, RANK() OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(n_p.charttime, i_set.intime, HOUR) ORDER BY n_p.charttime ASC) AS icu_timestep_rank

    FROM inclusion_set AS i_set
    LEFT JOIN Arterial_blood_pressure_part AS n_p
    ON i_set.subject_id = n_p.subject_id AND i_set.hadm_id = n_p.hadm_id AND i_set.stay_id = n_p.stay_id
  )
  SELECT *
  FROM Arterial_blood_pressure_raw
  WHERE Arterial_blood_pressure_raw.icu_timestep_rank = 1
  ORDER BY Arterial_blood_pressure_raw.stay_id, Arterial_blood_pressure_raw.charttime
  
), 
Arterial_blood_pressure_mbp AS
(
  WITH Arterial_blood_pressure_part AS
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime
    FROM inclusion_set AS i_set
    LEFT Join `physionet-data.mimiciv_icu.chartevents` AS chartevents 
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items 
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 220052
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  ), Arterial_blood_pressure_raw AS    
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, i_set.outtime, i_set.dod, n_p.value AS value, n_p.charttime AS charttime, 
    DATETIME_DIFF(n_p.charttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, n_p.charttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, n_p.charttime, HOUR) AS hosp_timestep_back, DATETIME_DIFF(i_set.dod, n_p.charttime, HOUR) AS death_timestep, RANK() OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(n_p.charttime, i_set.intime, HOUR) ORDER BY n_p.charttime ASC) AS icu_timestep_rank

    FROM inclusion_set AS i_set
    LEFT JOIN Arterial_blood_pressure_part AS n_p
    ON i_set.subject_id = n_p.subject_id AND i_set.hadm_id = n_p.hadm_id AND i_set.stay_id = n_p.stay_id
  )
  SELECT *
  FROM Arterial_blood_pressure_raw
  WHERE Arterial_blood_pressure_raw.icu_timestep_rank = 1
  ORDER BY Arterial_blood_pressure_raw.stay_id, Arterial_blood_pressure_raw.charttime
  
), 

Non_invasive_blood_pressure_sbp AS
(
  WITH Non_invasive_blood_pressure_part AS
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime
    FROM inclusion_set AS i_set
    LEFT Join `physionet-data.mimiciv_icu.chartevents` AS chartevents 
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items 
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 220179
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  ), Non_invasive_blood_pressure_raw AS    
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, i_set.outtime, i_set.dod, n_p.value AS value, n_p.charttime AS charttime, 
    DATETIME_DIFF(n_p.charttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, n_p.charttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, n_p.charttime, HOUR) AS hosp_timestep_back, DATETIME_DIFF(i_set.dod, n_p.charttime, HOUR) AS death_timestep, RANK() OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(n_p.charttime, i_set.intime, HOUR) ORDER BY n_p.charttime ASC) AS icu_timestep_rank

    FROM inclusion_set AS i_set
    LEFT JOIN Non_invasive_blood_pressure_part AS n_p
    ON i_set.subject_id = n_p.subject_id AND i_set.hadm_id = n_p.hadm_id AND i_set.stay_id = n_p.stay_id
  )
  SELECT *
  FROM Non_invasive_blood_pressure_raw
  WHERE Non_invasive_blood_pressure_raw.icu_timestep_rank = 1
  ORDER BY Non_invasive_blood_pressure_raw.stay_id, Non_invasive_blood_pressure_raw.charttime
  
)


, Non_invasive_blood_pressure_dbp AS
(
  WITH Non_invasive_blood_pressure_part AS
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime
    FROM inclusion_set AS i_set
    LEFT Join `physionet-data.mimiciv_icu.chartevents` AS chartevents 
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items 
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 220180
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  ), Non_invasive_blood_pressure_raw AS    
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, i_set.outtime, i_set.dod, n_p.value AS value, n_p.charttime AS charttime, 
    DATETIME_DIFF(n_p.charttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, n_p.charttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, n_p.charttime, HOUR) AS hosp_timestep_back, DATETIME_DIFF(i_set.dod, n_p.charttime, HOUR) AS death_timestep, RANK() OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(n_p.charttime, i_set.intime, HOUR) ORDER BY n_p.charttime ASC) AS icu_timestep_rank

    FROM inclusion_set AS i_set
    LEFT JOIN Non_invasive_blood_pressure_part AS n_p
    ON i_set.subject_id = n_p.subject_id AND i_set.hadm_id = n_p.hadm_id AND i_set.stay_id = n_p.stay_id
  )
  SELECT *
  FROM Non_invasive_blood_pressure_raw
  WHERE Non_invasive_blood_pressure_raw.icu_timestep_rank = 1
  ORDER BY Non_invasive_blood_pressure_raw.stay_id, Non_invasive_blood_pressure_raw.charttime
  
)



, Non_invasive_blood_pressure_mbp AS
(
  WITH Non_invasive_blood_pressure_part AS
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime
    FROM inclusion_set AS i_set
    LEFT Join `physionet-data.mimiciv_icu.chartevents` AS chartevents 
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items 
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 220181
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  ), Non_invasive_blood_pressure_raw AS    
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, i_set.outtime, i_set.dod, n_p.value AS value, n_p.charttime AS charttime, 
    DATETIME_DIFF(n_p.charttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, n_p.charttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, n_p.charttime, HOUR) AS hosp_timestep_back, DATETIME_DIFF(i_set.dod, n_p.charttime, HOUR) AS death_timestep, RANK() OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(n_p.charttime, i_set.intime, HOUR) ORDER BY n_p.charttime ASC) AS icu_timestep_rank

    FROM inclusion_set AS i_set
    LEFT JOIN Non_invasive_blood_pressure_part AS n_p
    ON i_set.subject_id = n_p.subject_id AND i_set.hadm_id = n_p.hadm_id AND i_set.stay_id = n_p.stay_id
  )
  SELECT *
  FROM Non_invasive_blood_pressure_raw
  WHERE Non_invasive_blood_pressure_raw.icu_timestep_rank = 1
  ORDER BY Non_invasive_blood_pressure_raw.stay_id, Non_invasive_blood_pressure_raw.charttime
  
)





, Manual_blood_pressure AS 
(
  WITH Manual_blood_pressure_part AS
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime, d_items.label AS label
    FROM inclusion_set AS i_set
    LEFT JOIN `physionet-data.mimiciv_icu.chartevents` AS chartevents 
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 224167 OR chartevents.itemid = 224643 OR chartevents.itemid = 227243 OR chartevents.itemid = 227242
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  )

  SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    m_p.value AS value, m_p.charttime AS charttime, m_p.label AS chartevent_name  
  FROM inclusion_set AS i_set
  LEFT JOIN Manual_blood_pressure_part AS m_p
  ON i_set.subject_id = m_p.subject_id AND i_set.hadm_id = m_p.hadm_id AND i_set.stay_id = m_p.stay_id

), Respiratory_rate AS  
(
  WITH Respiratory_rate_part AS 
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime, d_items.label AS label
    FROM inclusion_set AS i_set
    LEFT JOIN `physionet-data.mimiciv_icu.chartevents` AS chartevents 
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 220210 
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  ), Respiratory_rate_raw AS
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, i_set.dod AS dod, r_p.value AS value, r_p.charttime AS charttime,  
    DATETIME_DIFF(r_p.charttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, r_p.charttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, r_p.charttime, HOUR) AS hosp_timestap_back, DATETIME_DIFF(i_set.dod, r_p.charttime, HOUR) AS death_timestep, RANK() OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(r_p.charttime, i_set.intime, HOUR) ORDER BY r_p.charttime ASC) AS icu_timestep_rank
  FROM inclusion_set AS i_set
  LEFT JOIN Respiratory_rate_part AS r_p  
  ON i_set.subject_id = r_p.subject_id AND i_set.hadm_id = r_p.hadm_id AND i_set.stay_id = r_p.stay_id
  )
  
  SELECT *
  FROM Respiratory_rate_raw
  WHERE Respiratory_rate_raw.icu_timestep_rank = 1
  ORDER BY Respiratory_rate_raw.stay_id, Respiratory_rate_raw.charttime

  
), Respiratory_rate_total AS   
(
  
  WITH Respiratory_rate_total_part AS 
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime, d_items.label AS label
    FROM inclusion_set AS i_set
    LEFT JOIN `physionet-data.mimiciv_icu.chartevents` AS chartevents 
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 224690 
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  )
  SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, i_set.outtime AS outtime, 
    r_p.value AS value, r_p.charttime AS charttime, r_p.label AS chartevent_name
  FROM inclusion_set AS i_set
  LEFT JOIN Respiratory_rate_total_part AS r_p
  ON i_set.subject_id = r_p.subject_id AND i_set.hadm_id = r_p.hadm_id AND i_set.stay_id = r_p.stay_id

  
), Temperature_Celsius AS 
(

  WITH Temperature_Celsius_part AS 
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime, d_items.label AS label
    FROM inclusion_set AS i_set
    LEFT JOIN `physionet-data.mimiciv_icu.chartevents` AS chartevents
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 223762
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  ), Temperature_Celsius_raw AS
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, t_p.value AS value, t_p.charttime AS charttime,
    DATETIME_DIFF(t_p.charttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, t_p.charttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, t_p.charttime, HOUR) AS hosp_timestap_back, DATETIME_DIFF(i_set.dod, t_p.charttime, HOUR) AS death_timestep, RANK() OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(t_p.charttime, i_set.intime, HOUR) ORDER BY t_p.charttime ASC) AS icu_timestep_rank
  FROM inclusion_set AS i_set
  LEFT JOIN Temperature_Celsius_part AS t_p
  ON i_set.subject_id = t_p.subject_id AND i_set.hadm_id = t_p.hadm_id AND i_set.stay_id = t_p.stay_id
  )
  SELECT * 
  FROM Temperature_Celsius_raw
  WHERE Temperature_Celsius_raw.icu_timestep_rank = 1
  ORDER BY Temperature_Celsius_raw.stay_id, Temperature_Celsius_raw.charttime
  
), Temperature_fahrenheit AS 
(

  WITH Temperature_fahrenheit_part AS 
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime, d_items.label AS label
    FROM inclusion_set AS i_set
    LEFT JOIN `physionet-data.mimiciv_icu.chartevents` AS chartevents
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 223761
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  ), Temperature_fahrenheit_raw AS
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, t_p.value AS value, t_p.charttime AS charttime,
    DATETIME_DIFF(t_p.charttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, t_p.charttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, t_p.charttime, HOUR) AS hosp_timestap_back, DATETIME_DIFF(i_set.dod, t_p.charttime, HOUR) AS death_timestep, RANK() OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(t_p.charttime, i_set.intime, HOUR) ORDER BY t_p.charttime ASC) AS icu_timestep_rank
  FROM inclusion_set AS i_set
  LEFT JOIN Temperature_fahrenheit_part AS t_p
  ON i_set.subject_id = t_p.subject_id AND i_set.hadm_id = t_p.hadm_id AND i_set.stay_id = t_p.stay_id
  )
  SELECT * 
  FROM Temperature_fahrenheit_raw
  WHERE Temperature_fahrenheit_raw.icu_timestep_rank = 1
  ORDER BY Temperature_fahrenheit_raw.stay_id, Temperature_fahrenheit_raw.charttime
  
), SpO2 AS
(
  With SpO2_part AS 
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime, d_items.label AS label
    FROM inclusion_set AS i_set
    LEFT JOIN `physionet-data.mimiciv_icu.chartevents` AS chartevents
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 229862
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  )
  SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    s_p.value AS value, s_p.charttime AS charttime, s_p.label AS chartevent_name
  FROM inclusion_set AS i_set
  LEFT JOIN SpO2_part AS s_p  
  ON i_set.subject_id = s_p.subject_id AND i_set.hadm_id = s_p.hadm_id AND i_set.stay_id = s_p.stay_id
), Glucose AS
(
  WITH Glucose_part AS 
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, 
    chartevents.valuenum AS value, chartevents.charttime AS charttime, d_items.label AS label
    FROM inclusion_set AS i_set
    LEFT JOIN `physionet-data.mimiciv_icu.chartevents` AS chartevents
    ON i_set.subject_id = chartevents.subject_id AND i_set.hadm_id = chartevents.hadm_id AND i_set.stay_id = chartevents.stay_id
    LEFT JOIN `physionet-data.mimiciv_icu.d_items` AS d_items
    ON chartevents.itemid = d_items.itemid
    WHERE chartevents.itemid = 220621
    ORDER BY i_set.subject_id, i_set.intime, chartevents.charttime, chartevents.itemid
  ), Glucose_raw AS   
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, g_p.value AS value, g_p.charttime AS charttime,
    DATETIME_DIFF(g_p.charttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, g_p.charttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, g_p.charttime, HOUR) AS hosp_timestep_back, DATETIME_DIFF(i_set.dod, g_p.charttime, HOUR) AS death_timestep, RANK() OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(g_p.charttime, i_set.intime, HOUR) ORDER BY g_p.charttime ASC) AS icu_timestep_rank
    FROM inclusion_set AS i_set
    LEFT JOIN Glucose_part AS g_p
    ON i_set.subject_id = g_p.subject_id AND i_set.hadm_id = g_p.hadm_id AND i_set.stay_id = g_p.stay_id
  )
  SELECT * 
  FROM Glucose_raw
  WHERE Glucose_raw.icu_timestep_rank = 1
  ORDER BY Glucose_raw.stay_id, Glucose_raw.charttime
  
), Sofa AS 
(
  WITH Sofa_raw AS 
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime, sofa.sofa_24hours AS sofa, sofa.endtime AS charttime, 
    DATETIME_DIFF(sofa.starttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, sofa.starttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, sofa.starttime, HOUR) AS hosp_timestep_back, DATETIME_DIFF(i_set.dod, sofa.starttime, HOUR) AS death_timestep, 
  RANK () OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(sofa.starttime, i_set.intime, HOUR) ORDER BY sofa.starttime ASC) AS icu_timestep_rank
    FROM inclusion_set AS i_set
    LEFT JOIN `physionet-data.mimiciv_derived.sofa` AS sofa
    ON i_set.stay_id = sofa.stay_id
  )
  SELECT * 
  FROM Sofa_raw
  WHERE Sofa_raw.icu_timestep_rank = 1
  ORDER BY Sofa_raw.stay_id, Sofa_raw.charttime
), Kdigo_creatinine AS 
(
  WITH Kdigo_creatinine_raw AS
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime,kdigo_creatinine.charttime AS charttime, kdigo_creatinine.creat AS kdigo_creat, DATETIME_DIFF(kdigo_creatinine.charttime, i_set.intime, HOUR) AS icu_timestep, DATETIME_DIFF(i_set.outtime, kdigo_creatinine.charttime, HOUR) AS icu_timestep_back, DATETIME_DIFF(i_set.dischtime, kdigo_creatinine.charttime, HOUR) AS hosp_timestep_back, DATETIME_DIFF(i_set.dod, kdigo_creatinine.charttime, HOUR) AS death_timestep, RANK() OVER (PARTITION BY i_set.stay_id, DATETIME_DIFF(kdigo_creatinine.charttime, i_set.intime, HOUR) ORDER BY kdigo_creatinine.charttime) AS icu_timestep_rank
    FROM inclusion_set AS i_set
    LEFT JOIN `physionet-data.mimiciv_derived.kdigo_creatinine` AS kdigo_creatinine 
    ON i_set.hadm_id = kdigo_creatinine.hadm_id AND i_set.stay_id = kdigo_creatinine.stay_id
    ORDER BY i_set.subject_id, i_set.intime, kdigo_creatinine.charttime
  )
  SELECT *
  FROM Kdigo_creatinine_raw
  WHERE Kdigo_creatinine_raw.icu_timestep_rank = 1
  ORDER BY Kdigo_creatinine_raw.stay_id, Kdigo_creatinine_raw.charttime
), Kdigo_stage AS 
(
  SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime,
  kdigo_stages.charttime AS charttime, kdigo_stages.aki_stage AS aki_stage, DATETIME_DIFF(kdigo_stages.charttime, i_set.intime, day) AS charttime_diff
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.kdigo_stages` AS kdigo_stages
  ON i_set.subject_id = kdigo_stages.subject_id AND i_set.hadm_id = kdigo_stages.hadm_id AND i_set.stay_id  = kdigo_stages.stay_id
  ORDER BY i_set.subject_id, i_set.intime, kdigo_stages.charttime
), Kdigo_uo AS  
(
  WITH Kdigo_uo_raw AS    
  (
    SELECT i_set.subject_id AS subject_id, i_set.hadm_id AS hadm_id, i_set.stay_id AS stay_id, i_set.intime AS intime,
  kdigo_uo.charttime AS charttime, kdigo_uo.urineoutput_6hr AS urineoutput_6hr, kdigo_uo.urineoutput_12hr AS urineoutput_12hr, kdigo_uo.urineoutput_24hr AS urineoutput_24hr, 
    kdigo_uo.uo_rt_6hr AS uo_rt_6hr, kdigo_uo.uo_rt_12hr AS uo_rt_12hr, kdigo_uo.uo_rt_24hr AS uo_rt_24hr, 
    DATETIME_DIFF(kdigo_uo.charttime, i_set.intime, HOUR) - 24 AS icu_timestep, 
    RANK() OVER (PARTITION BY i_set.stay_id, (DATETIME_DIFF(kdigo_uo.charttime, i_set.intime, HOUR) - 24) ORDER BY kdigo_uo.charttime) AS icu_timestep_rank
    FROM inclusion_set AS i_set
    LEFT JOIN `physionet-data.mimiciv_derived.kdigo_uo` AS kdigo_uo
    ON i_set.stay_id = kdigo_uo.stay_id
    ORDER BY i_set.subject_id, i_set.intime, kdigo_uo.charttime
  )
  SELECT *
  FROM Kdigo_uo_raw
  WHERE Kdigo_uo_raw.icu_timestep_rank = 1
  ORDER BY Kdigo_uo_raw.stay_id, Kdigo_uo_raw.charttime
  
), Combined_comorbidity_index AS   
(
  SELECT *
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.charlson` AS charlson
  ON i_set.subject_id = charlson.subject_id AND i_set.hadm_id = charlson.hadm_id
), Apsiii AS   
(
  SELECT i_set.stay_id AS stay_id, apsiii.apsiii AS apsiii
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.apsiii` AS apsiii
  ON i_set.subject_id = apsiii.subject_id AND i_set.hadm_id = apsiii.hadm_id AND i_set.stay_id = apsiii.stay_id
), vitalsign AS
(
  SELECT HR.subject_id AS subject_id, HR.hadm_id AS hadm_id, HR.stay_id AS stay_id, HR.label_hosp AS label_hosp, HR.label_icu AS label_icu,
  HR.icu_timestep AS icu_timestep, HR.icu_timestep_back AS icu_timestep_back, HR.hosp_timestep_back AS hosp_timestep_back, 
  HR.value AS Heart_rate, 
  CASE
    WHEN (NISBP.value IS NULL AND ASBP.value IS NOT NULL) THEN ASBP.value
    ELSE NISBP.value
  END AS NI_SBP, 
  CASE
    WHEN (NIDBP.value IS NULL AND ADBP.value IS NOT NULL) THEN ADBP.value
    ELSE NIDBP.value
  END AS NI_DBP, 
  CASE
    WHEN (NIMBP.value IS NULL AND AMBP.value IS NOT NULL) THEN AMBP.value
    ELSE NIMBP.value
  END AS NI_MBP, ASBP.value AS A_SBP, ADBP.value AS A_DBP, AMBP.value AS A_MBP,
  G.value AS Glucose, 
  TF.value AS tempture_F, 
  CASE
    WHEN (TC.value IS NULL AND TF.value IS NOT NULL) THEN (TF.value - 32) * 5 / 9
    ELSE TC.value
  END AS tempture_C, sofa.sofa, KC.kdigo_creat AS kdigo_creat, 
  KU.urineoutput_6hr AS urineoutput_6hr, KU.urineoutput_12hr AS urineoutput_12hr, KU.urineoutput_24hr AS urineoutput_24hr,
  KU.uo_rt_6hr AS uo_rt_6hr, KU.uo_rt_12hr AS uo_rt_12hr, KU.uo_rt_24hr AS uo_rt_24hr
  
  FROM Heart_Rate AS HR
  LEFT JOIN Non_invasive_blood_pressure_sbp AS NISBP ON HR.stay_id = NISBP.stay_id AND HR.icu_timestep = NISBP.icu_timestep
  LEFT JOIN Non_invasive_blood_pressure_dbp AS NIDBP ON HR.stay_id = NIDBP.stay_id AND HR.icu_timestep = NIDBP.icu_timestep
  LEFT JOIN Non_invasive_blood_pressure_mbp AS NIMBP ON HR.stay_id = NIMBP.stay_id AND HR.icu_timestep = NIMBP.icu_timestep
  LEFT JOIN Respiratory_rate AS RR ON HR.stay_id = RR.stay_id AND HR.icu_timestep = RR.icu_timestep
  LEFT JOIN Glucose AS G ON HR.stay_id = G.stay_id AND HR.icu_timestep = G.icu_timestep
  LEFT JOIN Temperature_fahrenheit AS TF ON HR.stay_id = TF.stay_id AND HR.icu_timestep = TF.icu_timestep
  LEFT JOIN Temperature_Celsius AS TC ON HR.stay_id = TC.stay_id AND HR.icu_timestep = TC.icu_timestep
  LEFT JOIN Arterial_blood_pressure_sbp AS ASBP ON HR.stay_id = ASBP.stay_id AND HR.icu_timestep = ASBP.icu_timestep
  LEFT JOIN Arterial_blood_pressure_dbp AS ADBP ON HR.stay_id = ADBP.stay_id AND HR.icu_timestep = ADBP.icu_timestep
  LEFT JOIN Arterial_blood_pressure_mbp AS AMBP ON HR.stay_id = AMBP.stay_id AND HR.icu_timestep = AMBP.icu_timestep
  LEFT JOIN Sofa AS sofa ON HR.stay_id = sofa.stay_id AND HR.icu_timestep = sofa.icu_timestep
  LEFT JOIN Kdigo_creatinine AS KC ON HR.stay_id = KC.stay_id AND HR.icu_timestep = KC.icu_timestep
  LEFT JOIN Kdigo_uo AS KU ON HR.stay_id = KU.stay_id AND HR.icu_timestep = KU.icu_timestep
  ORDER BY HR.stay_id, HR.charttime
), Cancer_type AS
(
  SELECT i_set.hadm_id AS hadm_id, 
  MAX(CASE
    WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('140', '141', '142', '143', '144', '145', '146', '147', '148', '149') THEN 1
    WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C00', 'C01', 'C02', 'C03', 'C04', 'C05', 'CO6', 'C07', 'C08', 'C09', 'C10', 'C11', 'C12', 'C13', 'C14') Then 1
    ELSE 0
  END) AS Head_and_Neck_Cancer, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('150', '151', '152', '153', '154', '155', '156', '157', '158', '159') THEN 1
      wHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C15', 'C16', 'C17', 'C18', 'C19', 'C20', 'C21', 'C22', 'C23', 'C24', 'C25', 'C26') THEN 1
      ELSE 0
    END
  ) AS GI_Cancer, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('160', '161', '162', '163', '164', '165') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C30', 'C31', 'C32', 'C33', 'C34', 'C35', 'C36', 'C37', 'C38', 'C39') THEN 1
      ELSE 0
    END
  ) AS Respiratory_Cancer, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('170', '171', '173') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C47', 'C48', 'C48') THEN 1
      ELSE 0
    END
  ) AS Soft_Tissue_Cancer, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('174', '175') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C50') THEN 1
      ELSE 0
    END
  ) AS Breast_Cancer, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('179', '180', '181', '182', '183', '184') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C51', 'C52', 'C53', 'C54', 'C55', 'C56', 'C57', 'C58') THEN 1
      ELSE 0 
    END
  ) AS GYN_Cancer, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('185') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C61') THEN 1
      ELSE 0
    END
  ) AS Prostate_Cancer, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('188', '189') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C64', 'C65', 'C66', 'C67', 'C68') THEN 1
      ELSE 0
    END
  ) AS Urinary_Tract_Cancer, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('191', '192') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C70', 'C71', 'C72') THEN 1
      ELSE 0
    END
  ) AS CNS_Cancer, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('200', '201', '202') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C81', 'C82', 'C83', 'C84', 'C85', 'C86', 'C88') THEN 1
      ELSE 0
    END
  ) AS Lymphoma, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('203') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C90') THEN 1
      ELSE 0
    END
  ) AS Multiple_Myeloma, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('204', '205', '206', '207', '208') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C91', 'C92', 'C93', 'C94', 'C95') THEN 1
      ELSE 0
    END
  ) AS Leukemia, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('209') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C7A') THEN 1
      ELSE 0
    END
  ) AS Neuroendocrine_Tumors, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('196') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C77') THEN 1
      ELSE 0
    END
  ) AS Lymph_Node_Metastases, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('1970', '1971', '1972', '1973') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C780', 'C781', 'C782', 'C783') THEN 1
      ELSE 0
    END
  ) AS Respiratory_and_Intrathoracic_Organ_Metastases, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('1985') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C795') THEN 1
      ELSE 0
    END
  ) AS Bone_Metastases, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('1974', '1975', '1976', '1977', '1978') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C784', 'C785', 'C786', 'C787', 'C788') THEN 1
      ELSE 0
    END
  ) AS GI_Metastases, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('1983', '1984') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C793') THEN 1
      ELSE 0
    END
  ) AS Brain_and_Central_Nervous_System_Metastases, 
  MAX(
    CASE
      WHEN dx.icd_version = 9 AND LEFT(dx.icd_code, 3) in ('1986', '1987', '19882', '19889', '1990') THEN 1
      WHEN dx.icd_version = 10 AND LEFT(dx.icd_code, 3) in ('C796', 'C797', 'C798', 'C799', 'C800') THEN 1
      ELSE 0
    END
  ) AS Soft_tissue_Metastases

  FROM inclusion_set AS i_set
  LEFT JOIN dx AS dx ON i_set.subject_id = dx.subject_id AND i_set.hadm_id = dx.hadm_id
  GROUP BY i_set.hadm_id
), baseline AS
(
  SELECT *
  FROM inclusion_set AS i_set
  LEFT JOIN baseline_level_1 AS b1 ON i_set.stay_id = b1.stay_id
  LEFT JOIN baseline_level_2 AS b2 ON i_set.stay_id = b2.stay_id
  LEFT JOIN Combined_comorbidity_index AS CCI ON i_set.stay_id = CCI.stay_id
  LEFT JOIN Apsiii AS apsiii ON i_set.stay_id = apsiii.stay_id
  LEFT JOIN Cancer_type AS CT ON i_set.hadm_id = CT.hadm_id
),


-- measurements
bg_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, hadm_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.bg` as data
  on i_set.hadm_id = data.hadm_id and i_set.subject_id = data.subject_id
  WHERE data.subject_id is not null
),

first_day_lab_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, stay_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.first_day_lab` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id

),

blood_differential_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.blood_differential` as data
  on i_set.hadm_id = data.hadm_id and i_set.subject_id = data.subject_id
  WHERE data.subject_id is not null
),

cardiac_marker_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.cardiac_marker` as data
  on i_set.hadm_id = data.hadm_id and i_set.subject_id = data.subject_id
  WHERE data.subject_id is not null
),

chemistry_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.chemistry` as data
  on i_set.hadm_id = data.hadm_id and i_set.subject_id = data.subject_id
  WHERE data.subject_id is not null
),

coagulation_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.coagulation` as data
  on i_set.hadm_id = data.hadm_id and i_set.subject_id = data.subject_id
  WHERE data.subject_id is not null
),

complete_blood_count_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.complete_blood_count` as data
  on i_set.hadm_id = data.hadm_id and i_set.subject_id = data.subject_id
  WHERE data.subject_id is not null
),

creatinine_baseline_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.creatinine_baseline` as data
  on i_set.hadm_id = data.hadm_id
),
gcs_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, stay_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.gcs` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id
  WHERE data.subject_id is not null
),

height_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, stay_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.height` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id
  WHERE data.subject_id is not null
),

icp_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, stay_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.icp` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id
  WHERE data.subject_id is not null
),

inflammation_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.crp, RANK() OVER (PARTITION BY i_set.stay_id ORDER BY data.charttime ASC) AS rank
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.inflammation` as data
  on i_set.hadm_id = data.hadm_id and i_set.subject_id = data.subject_id
 -- WHERE data.subject_id is not null
),

oxygen_delivery_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.o2_delivery_device_1, RANK() OVER (PARTITION BY i_set.stay_id ORDER BY data.charttime ASC) AS rank
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.oxygen_delivery` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id
 
),

rhythm_data as(
  SELECT i_set.subject_id, data.* EXCEPT (subject_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.rhythm` as data
  on i_set.subject_id = data.subject_id

),

urine_output_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (stay_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.urine_output` as data
  on i_set.stay_id = data.stay_id
),

urine_output_rate_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (stay_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.urine_output_rate` as data
  on i_set.stay_id = data.stay_id
),
ventilator_setting_data as(
  SELECT i_set.subject_id, i_set.stay_id , (case when data.charttime is not null then 1 else 0 end) as ventilator_label ,
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.ventilator_setting` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id

),

vital_sign_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, stay_id) , i_set.label_hosp, label_icu , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.vitalsign` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id

),

-- first day ---------------------------------------------------------------

first_day_bg_data as( --all
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, stay_id)  
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.first_day_bg` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id

),

-- first_day_bg_art_data as(
--   SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, stay_id) , i_set.label_hosp, label_icu , 
--   FROM inclusion_set AS i_set
--   LEFT JOIN `physionet-data.mimiciv_derived.first_day_bg_art` as data
--   on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id

-- ),

first_day_gcs_data as( --only gcs_min
  SELECT i_set.subject_id, i_set.stay_id , data.gcs_min
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.first_day_gcs` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id

),

first_day_height_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, stay_id)
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.first_day_height` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id

),

first_day_rrt_data as(
  SELECT i_set.subject_id, i_set.stay_id , (case when dialysis_present is not null then 1 else 0 end) as dialysis_present , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.first_day_rrt` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id

),

first_day_sofa_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, stay_id) ,
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.first_day_sofa` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id

),

first_day_urine_output_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, stay_id) ,
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.first_day_urine_output` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id

),
first_day_vitalsign_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, stay_id) , 
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.first_day_vitalsign` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id

),
first_day_weight_data as(
  SELECT i_set.subject_id, i_set.stay_id , data.* EXCEPT (subject_id, stay_id) ,
  FROM inclusion_set AS i_set
  LEFT JOIN `physionet-data.mimiciv_derived.first_day_weight` as data
  on i_set.stay_id = data.stay_id and i_set.subject_id = data.subject_id

),

first_day_data as (
  SELECT 
  bg.*, 
  gcs.* except(stay_id, subject_id), 
  rrt.* except(stay_id, subject_id), 
  sofa.* except(stay_id, subject_id), 
  urine_output.* except(stay_id, subject_id), 
  weight.* except(stay_id, subject_id), 
  height.* except(stay_id, subject_id)

  FROM first_day_bg_data as bg

  LEFT JOIN first_day_gcs_data as gcs
  on bg.subject_id = gcs.subject_id and bg.stay_id = gcs.stay_id

  LEFT JOIN first_day_height_data as height
  ON bg.subject_id = height.subject_id and bg.stay_id = height.stay_id

  LEFT JOIN first_day_rrt_data as rrt
  ON bg.subject_id = rrt.subject_id and bg.stay_id = rrt.stay_id

  LEFT JOIN first_day_sofa_data as sofa
  ON bg.subject_id = sofa.subject_id and bg.stay_id = sofa.stay_id

  LEFT JOIN first_day_urine_output_data as urine_output
  ON bg.subject_id = urine_output.subject_id and bg.stay_id = urine_output.stay_id

  LEFT JOIN first_day_weight_data as weight
  ON bg.subject_id = weight.subject_id and bg.stay_id = weight.stay_id
)

-- SELECT COUNT (DISTINCT (stay_id))
SELECT DISTINCT* 
From rhythm_data
-- where rank = 1
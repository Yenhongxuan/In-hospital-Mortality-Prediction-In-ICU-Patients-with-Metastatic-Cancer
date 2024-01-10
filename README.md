# In-hospital-Mortality-Prediction-In-ICU-Patients-with-Metastatic-Cancer
## This project is based on MIMIC-IV dataset. 

### XGBoost
The folder *xgboost* contains all the file needed to run "XGBoost_RF.ipynb". When run, a new model will be trained and will be stored in "model.pkl". However, the analysis part will be based on the model we trained, which is "xgboost_model.pkl". Feel free to change the "model_path" if you want to switch into the newly trained model.

"xg_boost_pred.csv" stores the prediction of the model (the one in model_path) on the whole dataset.
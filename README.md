# In-hospital-Mortality-Prediction-In-ICU-Patients-with-Metastatic-Cancer
This is a repository predicting the mortality of patients with advanced cancer. The data come from the MIMIC-IC dataset


## Prepare the environment
To create a new conda environment, run the following command.
```
conda env create -f ms_final.yml
conda activate ms_final
```

## Data preparation
If yout want to collect the data by yourselt, please refer to ```./sql/includsion.sql```.

For off-the-shelf data, 

- ```./data``` contains the processed raw data for baseline and vitalsign features. 
- For the data for the lstm, please download the pre-processed .zip file which contains .npy files for training and inferece. [data_npy.zip](https://drive.google.com/file/d/1N7_VlapdD9S7zBUOTGdV5-diCtTdgJz0/view?usp=sharing). And run the following command. 
    ```
    cd to "root of repository"
    mkdir data_npy
    unzip data_npy.zip -d data_npy
    ```


## Running the experiment
### XGBoost
The folder *xgboost* contains all the file needed to run "XGBoost_RF.ipynb". When run, a new model will be trained and will be stored in "model.pkl". However, the analysis part will be based on the model we trained, which is "xgboost_model.pkl". Feel free to change the "model_path" if you want to switch into the newly trained model.

"xg_boost_pred.csv" stores the prediction of the model (the one in model_path) on the whole dataset.

### LSTM

#### Training
To train the lstm, you need to download the .npy file first, please refer to the part of data preparation. 

To train the lstm run the following command.
```
cd lstm
python main_new.py --train
```
The output and weights of model will be saved in ```./lstm/ouput_new/train```. If you want to specify the hyperparameters of path of the output directory, please run ```python main_new.py --help``` to get more information. 


#### Testing
For testing the lstm, please run the following command
```
cd lstm
python main_new.py --test --weight {path of the weight to use} --save_results
```
The test results will be saved in ```./lstm/ouput_new/test```


### Stacking SVM
To run the stacking SVM, run the following command. 
```
cd svm
python main.py
```
The result will be save in ```./svm/output```. For more hyperparameter, please refer to ```python main.py --help```
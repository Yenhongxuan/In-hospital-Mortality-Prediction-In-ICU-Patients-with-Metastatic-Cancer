import pandas as pd
import numpy as np
import os 
import argparse
import matplotlib.pyplot as plt
from sklearn.metrics import roc_curve, auc
from collections import defaultdict


gender_map = {1: 'Male', 0: 'Female'}
# race_mape = {1: 'Unknown', 2: 'Other', 3: 'Asian', 4: 'White', 5: 'Unable', 6: 'Black_African', 7: 'Indian_Alaska', 8: 'Hispanic_Latino'}
race_mape = {1: 'Other', 2: 'Other', 3: 'Asian', 4: 'White', 5: 'Other', 6: 'Black_African', 7: 'Other', 8: 'Hispanic_Latino'}
insurance_map = {1: 'Government', 2: 'Medicaid', 3: 'Medicare', 4: 'Private', 5: 'Self_pay', 6: 'Others'}
admission_map = {1: 'AMBULATORY_OBSERVATION',
                 2: 'DIRECT_EMER',
                 3: 'DIRECT OBSERVATION',
                 4: 'ELECTIVE', 
                 5: 'EU_OBSERVATION', 
                 6: 'EW_EMER',
                 7: 'OBSERVATION_ADMIT',
                 8: 'SURGICAL SAME DAY ADMISSION', 
                 9: 'URGENT'
                 }


def opt_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument('--exp_dir', type=str, default='./svm/output/exp0', help='directory where save the results')
    parser.add_argument('--baseline', type=str, default='./data/baseline_processed.csv', help='baseline')
    opt = parser.parse_args()
    return opt


def plot_roc_curve(y_true_hosp, y_pred_hosp, y_true_icu, y_pred_icu, y_true_die_24, y_pred_die_24, y_true_alive_24, y_pred_alive_24, file_name ,output_dir):
    fig, ax = plt.subplots(1, 4, figsize=(16, 4))
    # hosp part
    fpr, tpr, thresholds = roc_curve(y_true_hosp, y_pred_hosp)
    roc_auc = auc(fpr, tpr)
    ax[0].plot(fpr, tpr, color='darkorange', lw=2, label='ROC curve (area = {:.2f})'.format(roc_auc))
    ax[0].plot([0, 1], [0, 1], color='navy', lw=2, linestyle='--')
    ax[0].set_xlim(-0.05, 1.05)
    ax[0].set_ylim(-0.05, 1.05)
    ax[0].set_xlabel('False Positive Rate')
    ax[0].set_ylabel('True Positive Rate')
    ax[0].legend()
    ax[0].set_title('ROC curve (hosp)')
    

    # icu part
    fpr, tpr, thresholds = roc_curve(y_true_icu, y_pred_icu)
    roc_auc = auc(fpr, tpr)
    ax[1].plot(fpr, tpr, color='darkorange', lw=2, label='ROC curve (area = {:.2f})'.format(roc_auc))
    ax[1].plot([0, 1], [0, 1], color='navy', lw=2, linestyle='--')
    ax[1].set_xlim(-0.05, 1.05)
    ax[1].set_ylim(-0.05, 1.05)
    ax[1].set_xlabel('False Positive Rate')
    ax[1].set_ylabel('True Positive Rate')
    ax[1].legend()
    ax[1].set_title('ROC curve (icu)')


    # 24 die
    fpr, tpr, thresholds = roc_curve(y_true_die_24, y_pred_die_24)
    roc_auc = auc(fpr, tpr)
    ax[2].plot(fpr, tpr, color='darkorange', lw=2, label='ROC curve (area = {:.2f})'.format(roc_auc))
    ax[2].plot([0, 1], [0, 1], color='navy', lw=2, linestyle='--')
    ax[2].set_xlim(-0.05, 1.05)
    ax[2].set_ylim(-0.05, 1.05)
    ax[2].set_xlabel('False Positive Rate')
    ax[2].set_ylabel('True Positive Rate')
    ax[2].legend()
    ax[2].set_title('ROC curve (24 die)')


    # 24 alive
    fpr, tpr, thresholds = roc_curve(y_true_alive_24, y_pred_alive_24)
    roc_auc = auc(fpr, tpr)
    ax[3].plot(fpr, tpr, color='darkorange', lw=2, label='ROC curve (area = {:.2f})'.format(roc_auc))
    ax[3].plot([0, 1], [0, 1], color='navy', lw=2, linestyle='--')
    ax[3].set_xlim(-0.05, 1.05)
    ax[3].set_ylim(-0.05, 1.05)
    ax[3].set_xlabel('False Positive Rate')
    ax[3].set_ylabel('True Positive Rate')
    ax[3].legend()
    ax[3].set_title('ROC curve (24 alive)')



    plt.savefig(os.path.join(output_dir, file_name))

def main(opt):
    df_results = pd.read_csv(os.path.join(opt.exp_dir, 'result.csv'))
    df_baseline = pd.read_csv(os.path.join(opt.baseline))

    fairness_cols = ['stay_id', 'race', 'gender', 'insurance', 'admission_type']
    df_baseline = df_baseline[fairness_cols]

    df = pd.merge(df_results, df_baseline, on='stay_id', how='inner')
    
    for col in fairness_cols:
        if col == 'stay_id':
            continue
        elif col == 'gender':
            table = gender_map
        elif col == 'race':
            table = race_mape
        elif col == 'insurance':
            table = insurance_map
        elif col == 'admission_type':
            table = admission_map
        else:
            raise Exception('Unknown column')
        
        output_dir = os.path.join(opt.exp_dir, 'fairness', col)
        os.makedirs(output_dir, exist_ok=True)


        df_base = defaultdict(list)

        for key, value in table.items():
            target_df = df[df[col] == key]
            # print(target_df.shape)
            # print(value)

            print(target_df.shape)

            df_base[value].append(target_df)

            # if target_df.shape[0] == 0:
            #     continue
            # else:
            #     plot_roc_curve(target_df['label_hosp_gt'], target_df['label_hosp'], target_df['label_icu_gt'], target_df['label_icu'], target_df['die_24_gt'], target_df['die_24'], target_df['alive_24_gt'], target_df['alive_24'], 'roc_{}.png'.format(value), output_dir)
        
        for key, value in df_base.items():
      
            target_df = pd.concat(value, ignore_index=True)
            if target_df.shape[0] == 0:
                continue
            else:
                print(key, target_df.shape)
                plot_roc_curve(target_df['label_hosp_gt'], target_df['label_hosp'], target_df['label_icu_gt'], target_df['label_icu'], target_df['die_24_gt'], target_df['die_24'], target_df['alive_24_gt'], target_df['alive_24'], 'roc_{}.png'.format(key), output_dir)





if __name__ == '__main__':
    opt = opt_parser()
    main(opt)
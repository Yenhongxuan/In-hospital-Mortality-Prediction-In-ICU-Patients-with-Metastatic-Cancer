import os
import argparse
import pandas as pd
import sklearn
from sklearn.svm import SVC, SVR
from sklearn.metrics import confusion_matrix, roc_curve, auc
from sklearn.calibration import calibration_curve
import numpy as np
import seaborn as sns
import matplotlib.pyplot as plt
from cprint import cprint


# read data from the output of Xgboost and LSTM models
def data_preprocessing(opt):
    df_b = pd.read_csv(opt.r_b)
    df_v = pd.read_csv(opt.r_v)


    label_name = 'label_' + opt.type
    label_name_b = 'label_' + opt.type + '_baseline'
    label_name_v = 'label_' + opt.type + '_vitalsign'
    label_name_gt = 'label_' + opt.type + '_gt'
    df_v = df_v[['stay_id', label_name, label_name_gt]]
    df_b = df_b[['stay_id', label_name]]


    df_v.rename(columns={label_name: label_name_v}, inplace=True)
    df_b.rename(columns={label_name: label_name_b}, inplace=True)

    df = pd.merge(df_b, df_v, on='stay_id', how='inner')
    

    data_X = df[[label_name_b, label_name_v]].values
    data_y = df[[label_name_gt, 'stay_id']].values
    return data_X, data_y 

def plot_summary(y_true, y_pred, exp_dir):
    # plot the confusion matrix
    threshold = 0.5
    pred = y_pred > threshold
    cm = confusion_matrix(y_true, pred)
    fig, ax = plt.subplots(1, 1, figsize=(6, 4))
    sns.heatmap(cm, annot=True, fmt='d', ax=ax, cmap='Blues')
    ax.set_title('Confusion matrix for {}'.format(opt.type))
    ax.set_xlabel('Predicted label')
    ax.set_ylabel('True label')
    plt.savefig(os.path.join(exp_dir, 'confusion_matrix_{}.png'.format(opt.type)))

    tn, fp, fn, tp = cm.ravel()
    sensitivity = tp / (tp + fn)
    specificity = tn / (tn + fp)
    precision = tp / (tp + fp)
    recall = tp / (tp + fn)
    accuracy = (tp + tn) / (tp + tn + fp + fn)
    f1_score = 2 * (precision * recall) / (precision + recall)
    cprint.info('Label_{}: senesitivity: {:.2f}, specificity: {:.2f}, precision: {:.2f}, f1_score: {:.2f}, accuracy: {:.2f}'.format(opt.type, sensitivity, specificity, precision, f1_score, accuracy))



    # Plot the ROC curve
    fpr, tpr, thresholds = roc_curve(y_true, y_pred)
    roc_auc = auc(fpr, tpr)
    plt.figure(figsize=(10, 6))
    plt.plot(fpr, tpr, color='darkorange', lw=2, label='ROC curve (area = {:.2f})'.format(roc_auc))
    plt.plot([0, 1], [0, 1], color='navy', lw=2, linestyle='--')
    plt.xlim(-0.05, 1.05)
    plt.ylim(-0.05, 1.05)
    plt.xlabel('False Positive Rate')
    plt.ylabel('True Positive Rate')
    plt.title('ROC curve ({})'.format(opt.type))
    plt.legend(loc="lower right")
    plt.savefig(os.path.join(exp_dir, 'roc_curve_{}.png'.format(opt.type)))

    # plot the calibration curve
    pred = np.clip(y_pred, 0, 1)
    prob_true, prob_pred = calibration_curve(y_true, pred, n_bins=10)
    plt.figure(figsize=(10, 6))
    plt.plot(prob_pred, prob_true, marker='o', label='Predicted Probability')
    plt.plot([0, 1], [0, 1], linestyle='--', color='gray', label='Perfectly calibrated')

    plt.xlabel('Mean Predicted Probability')
    plt.ylabel('Fraction of Positives')
    plt.title('Calibration Plot {}'.format(opt.type))
    plt.legend()
    plt.savefig(os.path.join(exp_dir, 'calibration_curve_{}.png'.format(opt.type)))





# arguments for stacking SVM
def opt_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument('--r_b', type=str, default='./data/xg_boost_pred.csv', help='result of baseline') # predicted results from Xgboost
    parser.add_argument('--r_v', type=str, default='./data/lstm_pred.csv', help='result of vitalsign') # predicted results from LSTM
    parser.add_argument('--type', type=str, default='all', help='type of prediction label')
    parser.add_argument('--output_dir', type=str, default='./output')
    parser.add_argument('--save_results', action='store_true', help='Whether to save the results')
    opt = parser.parse_args()
    return opt


def main(opt):

    types = ['hosp', 'icu']

    # create the output directory
    os.makedirs(opt.output_dir, exist_ok=True)
    exp_index = len([dir for dir in os.listdir(opt.output_dir) if os.path.isdir(os.path.join(opt.output_dir, dir))])
    exp_dir = os.path.join(opt.output_dir, 'exp' + str(exp_index))
    os.makedirs(exp_dir, exist_ok=True)

    result_df = pd.DataFrame()

    if opt.type not in types and opt.type == 'all':

        for type in types:

            opt.type = type

            data_X, data_y = data_preprocessing(opt)

            clf = SVC(probability=True)
            clf.fit(data_X, data_y[:, 0])

            y_pred = clf.predict_proba(data_X)[:, 1]

            plot_summary(data_y[:, 0], y_pred, exp_dir)
            
            if opt.save_results:
                result_df['label_{}_gt'.format(type)] = data_y[:, 0]
                result_df['label_{}'.format(type)] = y_pred
                result_df['stay_id'] = data_y[:, 1]
    elif opt.type in types:
        data_X, data_y = data_preprocessing(opt)
            
        clf = SVC(probability=True)
        clf.fit(data_X, data_y[:, 0])

        y_pred = clf.predict_proba(data_X)[:, 1]

        plot_summary(data_y[:, 0], y_pred, exp_dir)
        
        if opt.save_results:
            result_df['label_{}_gt'.format(type)] = data_y[:, 0]
            result_df['label_{}'.format(type)] = y_pred
            result_df['stay_id'] = data_y[:, 1]
    else:
        raise Exception('Wrong type for input data of stacking SVM')

    if opt.save_results:
        result_df.to_csv(os.path.join(exp_dir, 'result.csv'))


if __name__ == '__main__':
    opt = opt_parser()
    main(opt)
import os
import sys
import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.optim as optim
from torch.utils.data import DataLoader, TensorDataset, Dataset
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import argparse
import sklearn
from sklearn.model_selection import StratifiedKFold
from sklearn.calibration import calibration_curve
from sklearn.metrics import confusion_matrix, classification_report, roc_curve, auc, mean_squared_error, r2_score
from tqdm import tqdm
from cprint import *
from collections import defaultdict
import seaborn as sns


threshold = 0.5

class LSTMModel(nn.Module):
    def __init__(self, input_size, hidden_size, num_layers, output_sizes, bidirectional=False):
        super(LSTMModel, self).__init__()
        self.hidden_size = hidden_size
        self.output_sizes = output_sizes
        self.num_layers = num_layers
        self.bidirectional = bidirectional
        self.lstm = nn.LSTM(input_size, hidden_size, num_layers, batch_first=True, bidirectional=bidirectional)
        self.fincal_hidden_size = hidden_size * 2 if bidirectional else hidden_size # 128 * D
        self.mlp_hidden_size = self.fincal_hidden_size * 2
        self.mlp = nn.Sequential(
            nn.Linear(self.fincal_hidden_size, self.mlp_hidden_size),
            nn.ReLU(),
            nn.Linear(self.mlp_hidden_size, self.mlp_hidden_size), 
            nn.ReLU(),
            nn.Linear(self.mlp_hidden_size, self.output_sizes[2]), 
            nn.ReLU()
        )
        # The LSTM contains 6 ourptus, including the
        # 1. mortality label for Hospital
        # 2. mortality label for ICU
        # 3. How many day will the patient leave the ICU
        # 4. How many day will the patient leave the Hospital
        # 5. Does the patient will die after 24 hours
        # 6. Does the patient will leave the ICU after 24 hours
        # In the final edition, we only take accout of the 1, 2, 5, 6 when computing the gradients of the model
        self.output_layers = nn.ModuleList()
        for i, output_size in enumerate(output_sizes):
            if i == 2 or i == 3:
                self.output_layers.append(self.mlp)
            else:
                self.output_layers.append(nn.Sequential(nn.Linear(self.fincal_hidden_size, output_size), nn.Sigmoid()))
    def forward(self, x):
        out, _ = self.lstm(x) # 64 * L * (D * 128)
        out = out[:, -1, :] # 64 * (D * 128)

        outputs = [output_layer(out) for output_layer in self.output_layers]
        outputs = torch.cat(outputs, dim=1)

        return outputs

class LearnableWeightedLoss(nn.Module):
    def __init__(self):
        super(LearnableWeightedLoss, self).__init__()
        self.bce_loss = nn.BCELoss()
        self.mse_loss = nn.MSELoss()
        # weights for the loss of each brancg output of the model
        self.bce_weight_1 = nn.Parameter(torch.tensor(1.0), requires_grad=True)
        self.bce_weight_2 = nn.Parameter(torch.tensor(1.0), requires_grad=True)
        self.bce_weight_3 = nn.Parameter(torch.tensor(1.0), requires_grad=True)
        self.bce_weight_4 = nn.Parameter(torch.tensor(1.0), requires_grad=True)
        self.mse_weight_1 = nn.Parameter(torch.tensor(1.0), requires_grad=True)
        self.mse_weight_2 = nn.Parameter(torch.tensor(1.0), requires_grad=True)
    def forward(self, outputs, targets):
        loss_bce_1 = self.bce_loss(outputs[:, 0], targets[:, 1])
        loss_bce_2 = self.bce_loss(outputs[:, 1], targets[:, 2])
        loss_bce_3 = self.bce_loss(outputs[:, 4], targets[:, 5])
        loss_bce_4 = self.bce_loss(outputs[:, 5], targets[:, 6])

        loss_mse_1 = self.mse_loss(outputs[:, 2], targets[:, 3])
        loss_mse_2 = self.mse_loss(outputs[:, 3], targets[:, 4])

        # options for computing total loss
        # total_loss = self.bce_weight_1 * loss_bce_1 + self.bce_weight_2 * loss_bce_2 + self.mse_weight_1 * loss_mse_1 + self.mse_weight_2 * loss_mse_2
        total_loss = self.bce_weight_1 * loss_bce_1 + self.bce_weight_2 * loss_bce_2 + self.bce_weight_3 * loss_bce_3 + self.bce_weight_4 * loss_bce_4
        # total_loss = self.mse_weight_1 * loss_mse_1 + self.mse_weight_2 * loss_mse_2
        # total_loss = self.mse_weight_2 * loss_mse_2

        return total_loss

class my_dataset(Dataset):
    def __init__(self, data_X, data_y, y_scale_factor):
        self.data_X = torch.tensor(data_X, dtype=torch.float32)
        self.data_y = torch.tensor(data_y, dtype=torch.float32)
        self.y_scale_factor = y_scale_factor
    def __getitem__(self, index):
        return self.data_X[index], self.data_y[index]
    def __len__(self):
        return self.data_X.shape[0]
# training functions
def train(model, optimizer, criterions, dataloader, device, opt):
    num_batches = len(dataloader)
    size = len(dataloader.dataset)
    epoch_loss = 0
    correct_hosp = 0
    correct_icu = 0
    correct_24hr_die = 0
    correct_24hr_alive = 0
    history_data = defaultdict(list)
    
    model.train()

    for X, y in tqdm(dataloader):
        X, y = X.to(device), y.to(device)
        outputs = model(X)

        loss = criterions(outputs, y)

        optimizer.zero_grad()
        loss.backward()
        optimizer.step()

        # Update the loss
        epoch_loss += loss.item()
        pred_hosp = (outputs[:, 0] > threshold)
        pred_icu = (outputs[:, 1] > threshold)
        pred_24hr_die = (outputs[:, 4] > threshold)
        pred_24hr_alive = (outputs[:, 5] > threshold)
        
        correct_hosp += pred_hosp.eq(y[:, 1]).sum().item()
        correct_icu += pred_icu.eq(y[:, 2]).sum().item()
        correct_24hr_die += pred_24hr_die.eq(y[:, 5]).sum().item()
        correct_24hr_alive += pred_24hr_alive.eq(y[:, 6]).sum().item()

        history_data['pred'].append(outputs.detach().cpu().numpy())
        history_data['gt'].append(y.detach().cpu().numpy())

    history_data['pred'] = np.concatenate(history_data['pred'], axis=0)
    history_data['gt'] = np.concatenate(history_data['gt'], axis=0)

    # calculate the total loss and accuracy for each label in the epoch
    avg_epoch_loss = epoch_loss / num_batches
    avg_acc_hosp = correct_hosp / size
    avg_acc_icu = correct_icu / size
    avg_acc_24hr_die = correct_24hr_die / size
    avg_acc_24hr_alive = correct_24hr_alive / size

    return avg_epoch_loss, avg_acc_hosp, avg_acc_icu, avg_acc_24hr_die, avg_acc_24hr_alive, history_data


def validation(model, criterions, dataloader, device, opt):
    num_batches = len(dataloader)
    size = len(dataloader.dataset)
    epoch_loss = 0
    correct_hosp = 0
    correct_icu = 0
    correct_24hr_die = 0
    correct_24hr_alive = 0

    model.eval()
    history_data = defaultdict(list)

    with torch.no_grad():
        for X, y in tqdm(dataloader):
            X, y_gpu = X.to(device), y.to(device)
            outputs = model(X)
           
            loss = criterions(outputs, y_gpu)
            epoch_loss += loss.item()
            pred_hosp = (outputs[:, 0] > threshold)
            pred_icu = (outputs[:, 1] > threshold)
            pred_24hr_die = (outputs[:, 4] > threshold)
            pred_24hr_alive = (outputs[:, 5] > threshold)

            correct_hosp += pred_hosp.eq(y_gpu[:, 1]).sum().item()
            correct_icu += pred_icu.eq(y_gpu[:, 2]).sum().item()
            correct_24hr_die += pred_24hr_die.eq(y_gpu[:, 5]).sum().item()
            correct_24hr_alive += pred_24hr_alive.eq(y_gpu[:, 6]).sum().item()            

            history_data['pred'].append(outputs.detach().cpu().numpy())
            history_data['gt'].append(y)

    history_data['pred'] = np.concatenate(history_data['pred'], axis=0)
    history_data['gt'] = np.concatenate(history_data['gt'], axis=0)

    # calculate the total loss and accuracy for each label in the epoch
    avg_epoch_loss = epoch_loss / num_batches
    avg_acc_hosp = correct_hosp / size
    avg_acc_icu = correct_icu / size
    avg_acc_24hr_die = correct_24hr_die / size
    avg_acc_24hr_alive = correct_24hr_alive / size

    return avg_epoch_loss, avg_acc_hosp, avg_acc_icu, avg_acc_24hr_die, avg_acc_24hr_alive, history_data


def plot_summary(history_data, fold_dir):

    # plot accuracy
    epochs = [ (i+1) for i in range(len(history_data['val_acc_hosp']))]
    plt.figure(figsize=(10, 6))
    plt.plot(epochs, history_data['val_acc_hosp'], label='Hospital {}'.format(history_data['val_acc_hosp'][-1]))
    plt.plot(epochs, history_data['val_acc_icu'], label='ICU {}'.format(history_data['val_acc_icu'][-1]))
    plt.plot(epochs, history_data['val_acc_24hr_die'], label='24hr_die {}'.format(history_data['val_acc_24hr_die'][-1]))
    plt.plot(epochs, history_data['val_acc_24hr_alive'], label='24hr_alive {}'.format(history_data['val_acc_24hr_alive'][-1]))
    plt.legend()
    plt.xlabel('Epoch')
    plt.ylabel('Accuracy')
    plt.title('Validation Accuracy')
    plt.savefig(os.path.join(fold_dir, 'val_acc.png'))


    # plot the confusion matrix 
    pred_hosp = history_data['val_data'][-1]['pred'][:, 0] > threshold
    pred_icu = history_data['val_data'][-1]['pred'][:, 1] > threshold
    pred_24hr_die = history_data['val_data'][-1]['pred'][:, 4] > threshold
    pred_24hr_alive = history_data['val_data'][-1]['pred'][:, 5] > threshold
    cm_hosp = confusion_matrix(history_data['val_data'][-1]['gt'][:, 1], pred_hosp)
    cm_icu = confusion_matrix(history_data['val_data'][-1]['gt'][:, 2], pred_icu)
    cm_24hr_die = confusion_matrix(history_data['val_data'][-1]['gt'][:, 5], pred_24hr_die)
    cm_24hr_alive = confusion_matrix(history_data['val_data'][-1]['gt'][:, 6], pred_24hr_alive)


    fig, ax = plt.subplots(1, 4, figsize=(16, 4))
    sns.heatmap(cm_hosp, annot=True, fmt='d', cmap='Blues', ax=ax[0])
    ax[0].set_title('Confusion Matrix for Hospital')
    ax[0].set_xlabel('Predicted label')
    ax[0].set_ylabel('True label')    
    tn, fp, fn, tp = cm_hosp.ravel()
    sensitivity = tp / (tp + fn)
    specificity = tn / (tn + fp)
    precision = tp / (tp + fp)
    recall = tp / (tp + fn)
    accuracy = (tp + tn) / (tp + tn + fp + fn)
    f1_score = 2 * (precision * recall) / (precision + recall)
    cprint.info('Label_hosp: senesitivity: {:.2f}, specificity: {:.2f}, precision: {:.2f}, f1_score: {:.2f}, accuracy: {:.2f}'.format(sensitivity, specificity, precision, f1_score, accuracy))


    sns.heatmap(cm_icu, annot=True, fmt='d', cmap='Blues', ax=ax[1])
    ax[1].set_title('Confusion Matrix for icu')
    ax[1].set_xlabel('Predicted label')
    ax[1].set_ylabel('True label')    
    tn, fp, fn, tp = cm_icu.ravel()
    sensitivity = tp / (tp + fn)
    specificity = tn / (tn + fp)
    precision = tp / (tp + fp)
    recall = tp / (tp + fn)
    accuracy = (tp + tn) / (tp + tn + fp + fn)
    f1_score = 2 * (precision * recall) / (precision + recall)
    cprint.info('Label_icu: senesitivity: {:.2f}, specificity: {:.2f}, precision: {:.2f}, f1_score: {:.2f}, accuracy: {:.2f}'.format(sensitivity, specificity, precision, f1_score, accuracy))

    sns.heatmap(cm_24hr_die, annot=True, fmt='d', cmap='Blues', ax=ax[2])
    ax[2].set_title('Confusion Matrix for 24hr_die')
    ax[2].set_xlabel('Predicted label')
    ax[2].set_ylabel('True label')
    tn, fp, fn, tp = cm_24hr_die.ravel()
    sensitivity = tp / (tp + fn)
    specificity = tn / (tn + fp)
    precision = tp / (tp + fp)
    recall = tp / (tp + fn)
    accuracy = (tp + tn) / (tp + tn + fp + fn)
    f1_score = 2 * (precision * recall) / (precision + recall)
    cprint.info('Label_24hr_die: senesitivity: {:.2f}, specificity: {:.2f}, precision: {:.2f}, f1_score: {:.2f}, accuracy: {:.2f}'.format(sensitivity, specificity, precision, f1_score, accuracy))

    sns.heatmap(cm_24hr_alive, annot=True, fmt='d', cmap='Blues', ax=ax[3])
    ax[3].set_title('Confusion Matrix for 24hr_alive')
    ax[3].set_xlabel('Predicted label')
    ax[3].set_ylabel('True label')
    tn, fp, fn, tp = cm_24hr_alive.ravel()
    sensitivity = tp / (tp + fn)
    specificity = tn / (tn + fp)
    precision = tp / (tp + fp)
    recall = tp / (tp + fn)
    accuracy = (tp + tn) / (tp + tn + fp + fn)
    f1_score = 2 * (precision * recall) / (precision + recall)
    cprint.info('Label_24hr_alive: senesitivity: {:.2f}, specificity: {:.2f}, precision: {:.2f}, f1_score: {:.2f}, accuracy: {:.2f}'.format(sensitivity, specificity, precision, f1_score, accuracy))

    plt.savefig(os.path.join(fold_dir, 'confusion_matrix_hosp.png'))

   
    # plot the roc auc curve for label hosp
    fpr, tpr, thresholds = roc_curve(history_data['val_data'][-1]['gt'][:, 1], history_data['val_data'][-1]['pred'][:, 0])
    roc_auc = auc(fpr, tpr)
    plt.figure(figsize=(10, 6))
    plt.plot(fpr, tpr, color='darkorange', lw=2, label='ROC curve (area = {:.2f})'.format(roc_auc))
    plt.plot([0, 1], [0, 1], color='navy', lw=2, linestyle='--')
    plt.xlim([-0.05, 1.05])
    plt.ylim([-0.05, 1.05])
    plt.xlabel('False Positive Rate (FPR)')
    plt.ylabel('True Positive Rate (TPR)')
    plt.title('ROC curve (Hosp)')
    plt.legend(loc="lower right")
    plt.savefig(os.path.join(fold_dir, 'roc_curve_hosp.png'))

    # plot the roc auc curve for label icu
    fpr, tpr, thresholds = roc_curve(history_data['val_data'][-1]['gt'][:, 2], history_data['val_data'][-1]['pred'][:, 1])
    roc_auc = auc(fpr, tpr)
    plt.figure(figsize=(10, 6))
    plt.plot(fpr, tpr, color='darkorange', lw=2, label='ROC curve (area = {:.2f})'.format(roc_auc))
    plt.plot([0, 1], [0, 1], color='navy', lw=2, linestyle='--')
    plt.xlim([-0.05, 1.05])
    plt.ylim([-0.05, 1.05])
    plt.xlabel('False Positive Rate (FPR)')
    plt.ylabel('True Positive Rate (TPR)')
    plt.title('ROC curve (ICU)')
    plt.legend(loc="lower right")
    plt.savefig(os.path.join(fold_dir, 'roc_curve_icu.png'))


    # plot the roc auc curve for label 24hr_die
    fpr, tpr, thresholds = roc_curve(history_data['val_data'][-1]['gt'][:, 5], history_data['val_data'][-1]['pred'][:, 4])
    roc_auc = auc(fpr, tpr)
    plt.figure(figsize=(10, 6))
    plt.plot(fpr, tpr, color='darkorange', lw=2, label='ROC curve (area = {:.2f})'.format(roc_auc))
    plt.plot([0, 1], [0, 1], color='navy', lw=2, linestyle='--')
    plt.xlim([-0.05, 1.05])
    plt.ylim([-0.05, 1.05])
    plt.xlabel('False Positive Rate (FPR)')
    plt.ylabel('True Positive Rate (TPR)')
    plt.title('ROC curve (24hr_die)')
    plt.legend(loc="lower right")
    plt.savefig(os.path.join(fold_dir, 'roc_curve_24hr_die.png'))
    

    # plot the roc auc curve for label 24hr_alive
    fpr, tpr, thresholds = roc_curve(history_data['val_data'][-1]['gt'][:, 6], history_data['val_data'][-1]['pred'][:, 5])
    roc_auc = auc(fpr, tpr)
    plt.figure(figsize=(10, 6))
    plt.plot(fpr, tpr, color='darkorange', lw=2, label='ROC curve (area = {:.2f})'.format(roc_auc))
    plt.plot([0, 1], [0, 1], color='navy', lw=2, linestyle='--')
    plt.xlim([-0.05, 1.05])
    plt.ylim([-0.05, 1.05])
    plt.xlabel('False Positive Rate (FPR)')
    plt.ylabel('True Positive Rate (TPR)')
    plt.title('ROC curve (24hr_alive)')
    plt.legend(loc="lower right")
    plt.savefig(os.path.join(fold_dir, 'roc_curve_24hr_alive.png'))


    # plot the calibration curve
    # label_hosp
    pred = np.clip(history_data['val_data'][-1]['pred'][:, 0], 0, 1)
    prob_true, prob_pred = calibration_curve(history_data['val_data'][-1]['gt'][:, 1], pred)
    plt.figure(figsize=(10, 6))
    plt.plot(prob_pred, prob_true, marker='o', label='Predicted Probability')
    plt.plot([0, 1], [0, 1], linestyle='--', color='gray', label='Perfectly calibrated')
    plt.xlabel('Mean Predicted Probability')
    plt.ylabel('Fraction of Positives')
    plt.title('Calibration Plot Hosp')
    plt.legend()
    plt.savefig(os.path.join(fold_dir, 'calibration_curve_Hosp.png'))
    
    # label_icu
    pred = np.clip(history_data['val_data'][-1]['pred'][:, 1], 0, 1)
    prob_true, prob_pred = calibration_curve(history_data['val_data'][-1]['gt'][:, 2], pred)
    plt.figure(figsize=(10, 6))
    plt.plot(prob_pred, prob_true, marker='o', label='Predicted Probability')
    plt.plot([0, 1], [0, 1], linestyle='--', color='gray', label='Perfectly calibrated')
    plt.xlabel('Mean Predicted Probability')
    plt.ylabel('Fraction of Positives')
    plt.title('Calibration Plot ICU')
    plt.legend()
    plt.savefig(os.path.join(fold_dir, 'calibration_curve_ICU.png'))

    # label_24hr_die
    pred = np.clip(history_data['val_data'][-1]['pred'][:, 4], 0, 1)
    prob_true, prob_pred = calibration_curve(history_data['val_data'][-1]['gt'][:, 5], pred)
    plt.figure(figsize=(10, 6))
    plt.plot(prob_pred, prob_true, marker='o', label='Predicted Probability')
    plt.plot([0, 1], [0, 1], linestyle='--', color='gray', label='Perfectly calibrated')
    plt.xlabel('Mean Predicted Probability')
    plt.ylabel('Fraction of Positives')
    plt.title('Calibration Plot 24hr_dir')
    plt.legend()
    plt.savefig(os.path.join(fold_dir, 'calibration_curve_24_die.png'))

    # label_24hr_alive
    pred = np.clip(history_data['val_data'][-1]['pred'][:, 5], 0, 1)
    prob_true, prob_pred = calibration_curve(history_data['val_data'][-1]['gt'][:, 6], pred)
    plt.figure(figsize=(10, 6))
    plt.plot(prob_pred, prob_true, marker='o', label='Predicted Probability')
    plt.plot([0, 1], [0, 1], linestyle='--', color='gray', label='Perfectly calibrated')
    plt.xlabel('Mean Predicted Probability')
    plt.ylabel('Fraction of Positives')
    plt.title('Calibration Plot 24hr_alive')
    plt.legend()
    plt.savefig(os.path.join(fold_dir, 'calibration_curve_24_alive.png'))

    # # Rescale the numerical label
    # icu_mses = []
    # icu_r2_scores = []
    # hosp_mses = []
    # hosp_r2_scores = []
    # for i in range(len(history_data['val_data'])):
    #     # timestep_gt = history_data['val_data'][i]['gt'][:, 2:] / opt.y_scale_factor
    #     # timestep_pred = history_data['val_data'][i]['pred'][:, 2:] / opt.y_scale_factor

    #     timestep_gt = history_data['val_data'][i]['gt'][:, 2:] 
    #     timestep_pred = history_data['val_data'][i]['pred'][:, 2:] 

    #     mse_icu = mean_squared_error(timestep_gt[:, 0], timestep_pred[:, 0])
    #     mse_hosp = mean_squared_error(timestep_gt[:, 1], timestep_pred[:, 1])
    #     icu_mses.append(mse_icu)
    #     hosp_mses.append(mse_hosp)

    #     r2_score_icu = r2_score(timestep_gt[:, 0], timestep_pred[:, 0])
    #     r2_score_hosp = r2_score(timestep_gt[:, 1], timestep_pred[:, 1])
    #     icu_r2_scores.append(r2_score_icu)
    #     hosp_r2_scores.append(r2_score_hosp)

    # epoches = [i + 1 for i in range(len(icu_mses))]
    # plt.figure(figsize=(10, 6))
    # plt.plot(epoches, hosp_mses, label=f'Hospital mse {hosp_mses[-1]}')
    # plt.plot(epoches, icu_mses, label=f'ICU mse {icu_mses[-1]}')
    # plt.xlabel('Epoch')
    # plt.ylabel('MSE')
    # plt.legend()
    # plt.savefig(os.path.join(fold_dir,'mse_hosp_icu.png'))

    # plt.figure(figsize=(10, 6))
    # plt.plot(epoches, icu_r2_scores, label=f'ICU r2 score {icu_r2_scores[-1]}')
    # plt.plot(epoches, hosp_r2_scores, label=f'Hospital r2 score {hosp_r2_scores[-1]}')
    # plt.xlabel('Epoch')
    # plt.ylabel('R2 score')
    # plt.legend()
    # plt.savefig(os.path.join(fold_dir, 'r2_score_hosp_icu.png'))


def k_fold_train(opt):
    # set the output directory
    train_dir = os.path.join(opt.output_dir, 'train')
    os.makedirs(train_dir, exist_ok=True)
    exp_index = len([dir for dir in os.listdir(train_dir) if os.path.isdir(os.path.join(train_dir, dir))])
    exp_dir = os.path.join(opt.output_dir, 'train', f'exp{exp_index}')
    os.makedirs(exp_dir, exist_ok=True)


    # set the device
    device = torch.device(f'cuda:{opt.device}' if torch.cuda.is_available() else 'cpu')
    # set random seed
    torch.manual_seed(42)
    np.random.seed(42)
    # Read the data
    data_X = np.load(os.path.join(opt.data_dir, 'data_X_train_new.npy'))
    data_y = np.load(os.path.join(opt.data_dir, 'data_y_train_new.npy'))


    # Initialize the KFold object
    skf = StratifiedKFold(n_splits=5, shuffle=True)
    for i, (train_index, val_index) in enumerate(skf.split(data_X, data_y[:, 1])):

        fold_dir = os.path.join(exp_dir, f'fold{i}')
        os.makedirs(fold_dir, exist_ok=True)

        # setup history
        history = defaultdict(list)

        # split the dataset into train and validation
        X_train, X_val = data_X[train_index], data_X[val_index]
        y_train, y_val = data_y[train_index], data_y[val_index]


        # Load the model
        output_sizes = [1, 1, 1, 1, 1, 1] # size of each output branch
        model = LSTMModel(opt.input_size, opt.hidden_size, opt.num_layers, output_sizes, opt.bidirectional)
        model = model.to(device)

        criterions = LearnableWeightedLoss()

        # set up the optimization configuration
        optimizer = optim.Adam(model.parameters(), lr=opt.lr)
        # optimizer = optim.Adam([{'params': model.parameters()}, {'params': criterions.parameters()}], lr=opt.lr)
        # optimizer = optim.SGD(model.parameters(), lr=opt.lr, momentum=0.9, weight_decay=0.0001)
       


        # set up the dataset
        train_ds = my_dataset(X_train, y_train, opt.y_scale_factor)
        val_ds = my_dataset(X_val, y_val, opt.y_scale_factor)
        train_dl = DataLoader(train_ds, opt.batch_size, shuffle=True, num_workers=4)
        val_dl = DataLoader(val_ds, opt.batch_size, shuffle=False, num_workers=4)



        val_acc_icu_best = 0
        # save the results for each epoch
        for epoch in range(opt.epoch):
            train_loss, train_acc_hosp, train_acc_icu, train_acc_24hr_die, train_acc_24hr_alive, train_data = train(model, optimizer, criterions, train_dl, device, opt)       
            val_loss, val_acc_hosp, val_acc_icu, val_acc_24hr_die, val_acc_24hr_alive, val_data = validation(model, criterions, val_dl, device, opt)
            cprint.info(f'Epoch: {epoch + 1}/{opt.epoch}')
            cprint.info(f'Training loss: {train_loss}, Training accuracy hosp: {train_acc_hosp}, Training accuracy icu: {train_acc_icu}, Training accuracy 24hr_die: {train_acc_24hr_die}, Training accuracy 24hr_alive: {train_acc_24hr_alive}')
            cprint.info(f'Validation loss: {val_loss}, Validation accuracy hosp: {val_acc_hosp}, Validation accuracy icu: {val_acc_icu}, Validation accuracy 24hr_die: {val_acc_24hr_die}, Validation accuracy 24hr_alive: {val_acc_24hr_alive}')
            history['train_loss'].append(train_loss)
            history['val_loss'].append(val_loss)
            history['train_acc_hosp'].append(train_acc_hosp)
            history['train_acc_icu'].append(train_acc_icu)
            history['val_acc_hosp'].append(val_acc_hosp) 
            history['val_acc_icu'].append(val_acc_icu)
            history['train_acc_24hr_die'].append(train_acc_24hr_die)
            history['val_acc_24hr_die'].append(val_acc_24hr_die)
            history['train_acc_24hr_alive'].append(train_acc_24hr_alive)
            history['val_acc_24hr_alive'].append(val_acc_24hr_alive)
            history['train_data'].append(train_data) 
            history['val_data'].append(val_data)

            # save the best model
            if val_acc_icu > val_acc_icu_best:
                val_acc_icu_best = val_acc_icu
                torch.save(model.state_dict(), os.path.join(fold_dir, f'best.pth'))


        plot_summary(history, fold_dir)
    

def test(opt):

    # set up the output directory
    test_dir = os.path.join(opt.output_dir, 'test')
    os.makedirs(test_dir, exist_ok=True)
    exp_index = len([dir for dir in os.listdir(test_dir) if os.path.isdir(os.path.join(test_dir, dir))])
    exp_dir = os.path.join(opt.output_dir, 'test', f'exp{exp_index}')
    os.makedirs(exp_dir, exist_ok=True)

    # set the history
    history = defaultdict(list)
    # set the device
    device = torch.device(f'cuda:{opt.device}' if torch.cuda.is_available() else 'cpu')
    # set random seed
    torch.manual_seed(42)
    np.random.seed(42)


    # Read the data
    # data_X = np.load(os.path.join(opt.data_dir, 'data_X_final.npy'))
    # data_y = np.load(os.path.join(opt.data_dir, 'data_y_final.npy'))
    
    data_X = np.load(os.path.join(opt.data_dir, 'data_X_final_test.npy'))
    data_y = np.load(os.path.join(opt.data_dir, 'data_y_final_test.npy'))

    # Load the model
    output_sizes = [1, 1, 1, 1, 1, 1] # size of each output branch
    model = LSTMModel(opt.input_size, opt.hidden_size, opt.num_layers, output_sizes, opt.bidirectional)
    model.load_state_dict(torch.load(opt.weight))
    model = model.to(device)

    criterions = LearnableWeightedLoss()
    optimizer = optim.Adam(model.parameters(), lr=opt.lr)

    test_ds = my_dataset(data_X, data_y, opt.y_scale_factor)
    test_dl = DataLoader(test_ds, opt.batch_size, shuffle=False, num_workers=4)

    # save the results
    test_loss, test_acc_hosp, test_acc_icu, test_acc_24hr_die, test_acc_24hr_alive, test_data = validation(model, criterions, test_dl, device, opt)
    history['val_loss'].append(test_loss)
    history['val_acc_hosp'].append(test_acc_hosp) 
    history['val_acc_icu'].append(test_acc_icu)
    history['val_acc_24hr_die'].append(test_acc_24hr_die)
    history['val_acc_24hr_alive'].append(test_acc_24hr_alive)
    history['val_data'].append(test_data)


    # display the results
    cprint.info(f'Test loss: {test_loss}, Test accuracy hosp: {test_acc_hosp}, Test accuracy icu: {test_acc_icu}, Test accuracy 24hr: {test_acc_24hr_die}, Test accuracy 24hr_alive: {test_acc_24hr_alive}')


    plot_summary(history, exp_dir)
    
    # save the predictions output as .csv file
    if opt.save_results:
        result = np.concatenate((data_y[:, 0:1], test_data['gt'][:, 1:3], test_data['gt'][:, 5:7], test_data['pred'][:, 0:2], test_data['pred'][:, -2:]), axis=1)
        columns_label = ['stay_id', 'label_hosp_gt', 'label_icu_gt', 'die_24_gt', 'alive_24_gt', 'label_hosp', 'label_icu', 'die_24', 'alive_24']
        df = pd.DataFrame(result, columns=columns_label)
        df.to_csv(os.path.join(exp_dir, 'result.csv'), index=False)


def main(opt):
    if opt.train:
        k_fold_train(opt)
    elif opt.test:
        test(opt)




# arguments for training and testing
def opt_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data_dir', type=str, default='../data_npy', help='directory of source data')
    parser.add_argument('--train', action='store_true', help='Train the model')
    parser.add_argument('--test', action='store_true', help='Test the model')
    parser.add_argument('--device', type=str, default='0') # number of gpu or use cpu cores
    parser.add_argument('--epoch', type=int, default=100)
    parser.add_argument('--lr', type=float, default=1e-3, help='learning rate')
    parser.add_argument('--batch_size', type=int, default=512)
    parser.add_argument('--input_size', type=int, default=12) # size of input features
    parser.add_argument('--hidden_size', type=int, default=128)
    parser.add_argument('--num_layers', type=int, default=2)
    parser.add_argument('--y_scale_factor', type=float, default=1/720) # Whether to scale the hours for leave the ICU and hospital
    parser.add_argument('--output_dir', type=str, default='./output_new')
    parser.add_argument('--bidirectional', action='store_true', help='Whether to use bidirectional LSTM')
    parser.add_argument('--weight', type=str) # default weight for testing
    parser.add_argument('--save_results', action='store_true', help='Whether to save the results') # whether to save the result predictions
    opt = parser.parse_args()
    return opt



if __name__ == '__main__':
    opt = opt_parser()
    main(opt)
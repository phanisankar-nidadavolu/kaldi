#!/bin/bash
# Copyright 2019   Phani Sankar Nidadavolu
# Apache 2.0.

. ./cmd.sh

set -e
stage=0
aug_list="reverb music noise babble clean"  #clean refers to the original train dir
use_ivectors=true
num_reverb_copies=1
num_copies=3

# Alignment directories
lda_mllt_ali=tri2_ali_100k_nodup
clean_ali=tri4_ali_nodup

# train directories for ivectors and TDNNs
ivector_trainset=train_100k_nodup
train_sets="train_100k_nodup train_nodup train_100k_nodup_sp train_nodup_sp"
eval_sets="train_dev eval2000 rt03"

. ./path.sh
. ./utils/parse_options.sh

if [ -e data/rt03 ]; then maybe_rt03=rt03; else maybe_rt03= ; fi

if [ $stage -le 0 ]; then
  # Adding simulated RIRs to the original data directory
  if [ ! -d "RIRS_NOISES" ]; then
    # Download the package that includes the real RIRs, simulated RIRs, isotropic noises and point-source noises
    wget --no-check-certificate http://www.openslr.org/resources/28/rirs_noises.zip
    unzip rirs_noises.zip
  fi

  # First create a train and eval lists for all noise and reverb conditions
  local/prepare_noise_and_reverb_lists_for_aug.sh data/rirs_info

  # Next create a foreground list for music
  python local/make_segments_files_for_musan_music.py
  python local/make_segments_files_for_chime3bg.py

  for name in musan_music chime3background; do

    inp_dir=data/$name
    out_dir=${inp_dir}_fg
    wav_dir=$(pwd -P)/wavfiles/$name

    [ ! -d $wav_dir ] && mkdir -p $wav_dir
    [ ! -d $out_dir ] && mkdir -p $out_dir

    extract-segments scp:$inp_dir/wav.scp $inp_dir/segmented_file ark,scp:$wav_dir/wav.ark,$out_dir/wav.scp

    awk '{print $1,$1}' $out_dir/wav.scp > $out_dir/utt2spk

    utils/utt2spk_to_spk2utt.pl $out_dir/utt2spk > $out_dir/spk2utt

    utils/fix_data_dir.sh $out_dir || exit 1;

    utils/data/get_reco2dur.sh $out_dir || exit 1;

    for mode in train eval; do
      utils/filter_scp.pl -f 2 ${inp_dir}_${mode}/utt2spk $inp_dir/segmented_file | \
        utils/subset_data_dir.sh --utt-list - $out_dir ${out_dir}_${mode} || exit 1;
    done
  done
  exit 0;
fi

if [ $stage -le 1 ]; then
  mode=train
  for train_set in $train_sets; do
    echo "$0: Preparing data/${train_set}_reverb directory"
    if [ ! -f data/$train_set/reco2dur ]; then
      utils/data/get_reco2dur.sh --nj 6 --cmd "$train_cmd" data/$train_set || exit 1;
    fi

    seed=123
    for copy in `seq 1 $num_copies`; do
      # Augment with musan_noise
      steps/data/augment_data_dir.py --utt-prefix "noise-copy$copy" --modify-spk-id "true" \
        --random-seed $seed \
        --fg-interval 1 --fg-snrs "15:10:5:0" --fg-noise-dir "data/musan_noise_${mode}" \
        data/${train_set} data/additive/${train_set}_noise_${mode}_copy$copy
      seed=$((seed+1))
    done

    seed=123
    for copy in `seq 1 $num_copies`; do
      # Augment with musan_music
      steps/data/augment_data_dir.py --utt-prefix "music-copy$copy" --modify-spk-id "true" \
        --random-seed $seed \
        --bg-snrs "15:10:5:0" --num-bg-noises "1" --bg-noise-dir "data/musan_music_${mode}" \
        data/${train_set} data/additive/${train_set}_music_${mode}_copy$copy
      seed=$((seed+1))
    done

    seed=123
    for copy in `seq 1 $num_copies`; do
      # Augment with musan_chime3bg
      steps/data/augment_data_dir.py --utt-prefix "chime3bg-copy$copy" --modify-spk-id "true" \
        --random-seed $seed \
        --bg-snrs "15:10:5:0" --num-bg-noises "1" --bg-noise-dir "data/chime3background_${mode}" \
        data/${train_set} data/additive/${train_set}_chime3_${mode}_copy$copy
      seed=$((seed+1))
    done

    seed=123
    for copy in `seq 1 $num_copies`; do
      # Augment with musan_music_fg
      steps/data/augment_data_dir.py --utt-prefix "musicfg-copy$copy" --modify-spk-id "true" \
        --random-seed $seed \
        --fg-interval 1 --fg-snrs "15:10:5:0" --fg-noise-dir "data/musan_music_fg_${mode}" \
        data/${train_set} data/additive/${train_set}_music_fg_${mode}_copy$copy
      seed=$((seed+1))
    done

    seed=123
    for copy in `seq 1 $num_copies`; do
      # Augment with musan_chime3bg_fg
      steps/data/augment_data_dir.py --utt-prefix "chime3fg-copy$copy" --modify-spk-id "true" \
        --random-seed $seed \
        --fg-interval 1 --fg-snrs "15:10:5:0" --fg-noise-dir "data/chime3background_fg_${mode}" \
        data/${train_set} data/additive/${train_set}_chime3_fg_${mode}_copy$copy
      seed=$((seed+1))
    done

    seed=123
    for copy in `seq 1 $num_copies`; do
      # Augment with musan_speech
      steps/data/augment_data_dir.py --utt-prefix "babble-copy$copy" --modify-spk-id "true" \
        --random-seed $seed \
        --bg-snrs "22:17:12:7" --num-bg-noises "3:4:5:6:7" \
        --bg-noise-dir "data/musan_speech" \
        data/${train_set} data/additive/${train_set}_babble_${mode}_copy$copy
      seed=$((seed+1))
    done
  done
fi


if [ $stage -le 2 ]; then
  for rt60_max in 0.5 0.6 0.7 0.8 0.9 1.0; do
    awk -v r=$rt60_max '$3 < r {print $0}' data/rirs_info/simrirs2rt60.map | \
        utils/filter_scp.pl -f 2 -  data/rirs_info/rir_list.train > data/rirs_info/rir_list_train_rt60_min_0.0_max_${rt60_max}
  done

  for train_set in $train_sets; do
  for rt60_max in 0.5 0.6 0.7 0.8 0.9 1.0; do
    seed=0
    for copy in `seq 1 $num_copies`; do
      # Make a version with reverberated speech
      rvb_opts=()
      rvb_opts+=(--rir-set-parameters "0.5, data/rirs_info/rir_list_train_rt60_min_0.0_max_${rt60_max}")

      # Make a reverberated version of the SWBD train_nodup.
      # Note that we don't add any additive noise here.
      steps/data/reverberate_data_dir.py \
        "${rvb_opts[@]}" \
        --speech-rvb-probability 1 \
        --prefix "reverb-rt60max-${rt60_max}-copy$copy" \
        --random-seed $seed \
        --pointsource-noise-addition-probability 0 \
        --isotropic-noise-addition-probability 0 \
        --num-replications $num_reverb_copies \
        --source-sampling-rate 8000 \
        data/$train_set data/reverb/${train_set}_reverb_rt60_min_0_max_${rt60_max}_${mode}_copy$copy
      seed=$((seed+1))
      utils/data/get_reco2dur.sh --nj 6 --cmd "$train_cmd" data/reverb/${train_set}_reverb_rt60_min_0_max_${rt60_max}_${mode}_copy$copy || exit 1;
    done
  done
  done
fi

if [ $stage -le 3 ]; then
  mode=train
  for train_set in $train_sets; do
  for rt60_max in 0.5 0.6 0.7 0.8 0.9 1.0; do
    seed=123
    for copy in `seq 1 $num_copies`; do
      # Augment with musan_noise
      steps/data/augment_data_dir.py --utt-prefix "noise-copy$copy" --modify-spk-id "true" \
        --random-seed $seed \
        --fg-interval 1 --fg-snrs "15:10:5:0" --fg-noise-dir "data/musan_noise_${mode}" \
        data/reverb/${train_set}_reverb_rt60_min_0_max_${rt60_max}_${mode}_copy$copy \
        data/reverb/${train_set}_reverb_rt60_min_0_max_${rt60_max}_noise_${mode}_copy$copy
      seed=$((seed+1))
    done
  done
  done
fi

if [ $stage -le 4 ]; then
  mode=eval
  for eval_set in $eval_sets; do
    echo "$0: Preparing data/${eval_set}_reverb directory"
    if [ ! -f data/$eval_set/reco2dur ]; then
      utils/data/get_reco2dur.sh --nj 6 --cmd "$train_cmd" data/$eval_set || exit 1;
    fi

    num_eval_copies=1
    seed=123
    for copy in `seq 1 $num_eval_copies`; do
      # Augment with musan_noise
      steps/data/augment_data_dir.py --utt-prefix "noise" --modify-spk-id "true" \
        --random-seed $seed \
        --fg-interval 1 --fg-snrs "13:8:3:-2" --fg-noise-dir "data/musan_noise_${mode}" \
        data/${eval_set} data/additive/${eval_set}_noise_${mode}
      seed=$((seed+1))
    done

    seed=123
    for copy in `seq 1 $num_eval_copies`; do
      # Augment with musan_music
      steps/data/augment_data_dir.py --utt-prefix "music" --modify-spk-id "true" \
        --random-seed $seed \
        --bg-snrs "13:8:3:-2" --num-bg-noises "1" --bg-noise-dir "data/musan_music_${mode}" \
        data/${eval_set} data/additive/${eval_set}_music_${mode}
      seed=$((seed+1))
    done

    seed=123
    for copy in `seq 1 $num_eval_copies`; do
      # Augment with musan_chime3bg
      steps/data/augment_data_dir.py --utt-prefix "chime3bg" --modify-spk-id "true" \
        --random-seed $seed \
        --bg-snrs "13:8:3:-2" --num-bg-noises "1" --bg-noise-dir "data/chime3background_${mode}" \
        data/${eval_set} data/additive/${eval_set}_chime3_${mode}
      seed=$((seed+1))
    done

    seed=123
    for copy in `seq 1 $num_eval_copies`; do
      # Augment with musan_music_fg
      steps/data/augment_data_dir.py --utt-prefix "musicfg" --modify-spk-id "true" \
        --random-seed $seed \
        --fg-interval 1 --fg-snrs "13:8:3:-2" --fg-noise-dir "data/musan_music_fg_${mode}" \
        data/${eval_set} data/additive/${eval_set}_music_fg_${mode}
      seed=$((seed+1))
    done

    seed=123
    for copy in `seq 1 $num_eval_copies`; do
      # Augment with musan_chime3bg_fg
      steps/data/augment_data_dir.py --utt-prefix "chime3fg" --modify-spk-id "true" \
        --random-seed $seed \
        --fg-interval 1 --fg-snrs "15:10:5:0" --fg-noise-dir "data/chime3background_fg_${mode}" \
        data/${eval_set} data/additive/${eval_set}_chime3_fg_${mode}
      seed=$((seed+1))
    done

    seed=123
    for copy in `seq 1 $num_eval_copies`; do
      # Augment with musan_speech
      steps/data/augment_data_dir.py --utt-prefix "babble" --modify-spk-id "true" \
        --random-seed $seed \
        --bg-snrs "22:17:12:7" --num-bg-noises "3:4:5:6:7" \
        --bg-noise-dir "data/musan_speech" \
        data/${eval_set} data/additive/${eval_set}_babble_${mode}
      seed=$((seed+1))
    done
  done
  exit 0;
fi

if [ $stage -le 5 ]; then

  mode=eval
  num_eval_copies=1
  for eval_set in $eval_sets; do
    for rt60_range in min_0.0_max_0.5 min_0.5_max_1.0 min_1.0_max_1.5 min_1.5_max_4.0; do
      seed=0
      for copy in `seq 1 $num_eval_copies`; do
        # Make a version with reverberated speech
        rvb_opts=()
        rvb_opts+=(--rir-set-parameters "0.5, data/rirs_info/rir_list_${mode}_rt60_${rt60_range}")

        # Make a reverberated version of the SWBD train_nodup.
        # Note that we don't add any additive noise here.
        steps/data/reverberate_data_dir.py \
          "${rvb_opts[@]}" \
          --speech-rvb-probability 1 \
          --prefix "reverb" \
          --random-seed $seed \
          --pointsource-noise-addition-probability 0 \
          --isotropic-noise-addition-probability 0 \
          --num-replications $num_reverb_copies \
          --source-sampling-rate 8000 \
          data/$eval_set data/reverb/${eval_set}_reverb_rt60_${rt60_range}_${mode}
        seed=$((seed+1))
        utils/data/get_reco2dur.sh --nj 6 --cmd "$train_cmd" \
            data/reverb/${eval_set}_reverb_rt60_${rt60_range}_${mode} || exit 1;
      done
    done
  done
fi

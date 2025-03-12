ARG DOCKER_REPOSITORY
ARG DOCKER_TAG=latest
FROM ${DOCKER_REPOSITORY}alltalk_tts_environment:${DOCKER_TAG}

# Argument to choose the model: piper, vits, xtts
ARG TTS_MODEL="xtts"
ENV TTS_MODEL=$TTS_MODEL

ARG DEEPSPEED_VERSION=0.16.2
ENV DEEPSPEED_VERSION=$DEEPSPEED_VERSION

ARG ALLTALK_DIR=/opt/alltalk

ENV GRADIO_SERVER_NAME="0.0.0.0"

# Switch for using the multi engine manager:
ENV ALLTALK_ENABLE_MULTI_ENGINE_MANAGER=false

# Default settings used in docker_default_confignew.json:
ENV ALLTALK_DELETE_OUTPUT_WAVS="1"
ENV ALLTALK_GRADIO_INTERFACE=true
ENV ALLTALK_RVC_ENABLED=true
ENV ALLTALK_RVC_F0METHOD="rmvpe"

# Default settings used in docker_default_mem_config.json:
ENV ALLTALK_MEM_AUTO_START_ENGINES=1
ENV ALLTALK_MEM_MAX_INSTANCES=1

WORKDIR ${ALLTALK_DIR}

##############################################################################
# Download TTS models:
##############################################################################
COPY system/tts_engines/piper/available_models.json system/tts_engines/piper/
COPY system/tts_engines/vits/available_models.json system/tts_engines/vits/
COPY system/tts_engines/xtts/available_models.json system/tts_engines/xtts/
RUN <<EOR
    available_models="system/tts_engines/${TTS_MODEL}/available_models.json"
    first_start_model=$(cat ${available_models} | jq -r '.first_start_model')
    model=$(cat ${available_models} | jq ".models[] | select(.model_name==\"${first_start_model}\")")
    folder_path=$( echo "${model}" | jq -r '.folder_path // empty' )
    files_to_download=$( echo "${model}" | jq '.files_to_download[]?' )
    github_rls_url=$( echo "${model}" | jq '.github_rls_url // empty' )

    # Special case for vits: firstrun.py expects the ZIP download directly in the model folder.
    # When firstrun.py unzips the file, the correct folder will be created automatically.
    if [[ "$TTS_MODEL" == "vits" ]]; then
      folder_path=""
    fi

    # Merging both fields:
    files_to_download="${files_to_download} ${github_rls_url}"
    target_dir="models/${TTS_MODEL}/${folder_path}"

    echo "$files_to_download" | xargs -n 1 curl --create-dirs --output-dir "${target_dir}" -LO
EOR

##############################################################################
# Download all RVC models:
##############################################################################
COPY system/tts_engines/rvc_files.json system/tts_engines/
RUN <<EOR
  rvc_files=$( jq -r '.[]' system/tts_engines/rvc_files.json )
  echo "$rvc_files" | xargs -n 1 curl --create-dirs --output-dir models/rvc_base -LO
EOR

##############################################################################
# Install python dependencies (cannot use --no-deps because requirements are not complete)
##############################################################################
COPY system/config/*.whl system/config/
COPY system/requirements/requirements_standalone.txt system/requirements/requirements_standalone.txt
COPY system/requirements/requirements_parler.txt system/requirements/requirements_parler.txt
ENV PIP_CACHE_DIR=${ALLTALK_DIR}/pip_cache
RUN <<EOR
    conda activate alltalk

    mkdir ${ALLTALK_DIR}/pip_cache
    pip install --no-cache-dir --cache-dir=${ALLTALK_DIR}/pip_cache -r system/requirements/requirements_standalone.txt
    pip install --no-cache-dir --cache-dir=${ALLTALK_DIR}/pip_cache --upgrade gradio==4.32.2

    # By default, version 1.9.10 is used causing this warning on startup: 'FutureWarning: `torch.cuda.amp.autocast(args...)` is deprecated'
    pip install --no-cache-dir --cache-dir=${ALLTALK_DIR}/pip_cache local-attention==1.11.1

    # Parler:
    pip install --no-cache-dir --cache-dir=${ALLTALK_DIR}/pip_cache -r system/requirements/requirements_parler.txt

    conda clean --all --force-pkgs-dirs -y && pip cache purge
EOR

##############################################################################
# Install DeepSpeed
##############################################################################
RUN mkdir -p /tmp/deepspeed
COPY docker/deepspeed/build*/*.whl /tmp/deepspeed/
RUN <<EOR
    DEEPSPEED_WHEEL=$(realpath -q /tmp/deepspeed/*.whl)
    conda activate alltalk

    # Download DeepSpeed wheel if it was not built locally:
    if [ -z "${DEEPSPEED_WHEEL}" ] || [ ! -f $DEEPSPEED_WHEEL ] ; then
      echo "Downloading pre-built DeepSpeed wheel"
      CURL_ERROR=$( { curl --output-dir /tmp/deepspeed -fLO "https://github.com/erew123/alltalk_tts/releases/download/DeepSpeed-for-docker/deepspeed-0.16.2+b344c04d-cp311-cp311-linux_x86_64.whl" ; } 2>&1 )
      if [ $? -ne 0 ] ; then
        echo "Failed to download DeepSpeed: $CURL_ERROR"
        exit 1
      fi
      DEEPSPEED_WHEEL=$(realpath -q /tmp/deepspeed/*.whl)
    fi

    echo "Using precompiled DeepSpeed wheel at ${DEEPSPEED_WHEEL}"
    CFLAGS="-I$CONDA_PREFIX/include/" LDFLAGS="-L$CONDA_PREFIX/lib/" \
      pip install --no-cache-dir ${DEEPSPEED_WHEEL}

    if [ $? -ne 0 ] ; then
      echo "Failed to install pip dependencies: $RESULT"
      exit 1
    fi

    rm ${DEEPSPEED_WHEEL}
    conda clean --all --force-pkgs-dirs -y && pip cache purge
EOR

##############################################################################
# Writing scripts to start alltalk:
##############################################################################
RUN <<EOR
    cat << EOF > start_alltalk.sh
#!/usr/bin/env bash
source ~/.bashrc

replace_env_vars() {
  echo "{}" > /tmp/empty.json
  jq "\$( cat \$1 ) | del(.. | select(. == null))" /tmp/empty.json > \$1.tmp
  mv \$1.tmp \$1
  rm -f /tmp/empty.json
}

merge_json_files() {
  # Merging JSON config with docker default values followed by values set on startup:
  jq -s '.[0] * .[1] * .[2]' \$1 docker_default_\$1 docker_\$1  > \$1.tmp
  mv \$1.tmp \$1
}

replace_env_vars docker_default_confignew.json
merge_json_files confignew.json

conda activate alltalk

if [ "\$ALLTALK_ENABLE_MULTI_ENGINE_MANAGER" = true ] ; then
  echo "Starting alltalk using multi engine manager"
  replace_env_vars docker_default_mem_config.json
  merge_json_files mem_config.json
  python tts_mem.py
else
  echo "Starting alltalk"
  python script.py
fi
EOF
    cat << EOF > start_finetune.sh
#!/usr/bin/env bash
source ~/.bashrc
export TRAINER_TELEMETRY=0
conda activate alltalk
python finetune.py
EOF
    cat << EOF > start_diagnostics.sh
#!/usr/bin/env bash
source ~/.bashrc
conda activate alltalk
python diagnostics.py
EOF
    chmod +x start_alltalk.sh
    chmod +x start_finetune.sh
    chmod +x start_diagnostics.sh
EOR

COPY . .

##############################################################################
# Create script to execute firstrun.py and run it:
##############################################################################
RUN echo $'#!/usr/bin/env bash \n\
source ~/.bashrc \n\
conda activate alltalk \n\
python ./system/config/firstrun.py $@' > ./start_firstrun.sh

RUN chmod +x start_firstrun.sh
RUN ./start_firstrun.sh --tts_model $TTS_MODEL

RUN mkdir -p ${ALLTALK_DIR}/outputs
RUN mkdir -p /root/.triton/autotune

##############################################################################
# Enable deepspeed for all models:
##############################################################################
RUN find . -name model_settings.json -exec sed -i -e 's/"deepspeed_enabled": false/"deepspeed_enabled": true/g' {} \;

##############################################################################
# Start alltalk:
##############################################################################
ENTRYPOINT ["sh", "-c", "./start_alltalk.sh"]

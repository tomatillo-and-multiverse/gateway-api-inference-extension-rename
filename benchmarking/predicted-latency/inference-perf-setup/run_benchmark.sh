#!/bin/bash

# Default internal IP (for the first 3 runs)
INTERNAL_IP= <your gateway IP here>

# NEW: The External IP for the 4th run
EXTERNAL_IP= <your external IP here> # for k8 runs

SCENARIOS=(
  # Load + Prefix Cache

  "scenario-A-predicted-latency-only-load-prefix-1 1 1 1 0 $INTERNAL_IP false 0.8 0.99 inference-perf-qwen-llm-d-comparison-final-179 0 0 true"
  "scenario-A-predicted-latency-only-load-prefix-2 3 2 2 0 $INTERNAL_IP true 0.8 0.99 inference-perf-qwen-llm-d-comparison-final-179 0 0 true"

  "scenario-A-predicted-latency-only-latency-predictor 0 0 0 1 $INTERNAL_IP true 0.8 0.99 inference-perf-qwen-llm-d-comparison-final-179 0 0 true"
  "scenario-A-predicted-latency-only-k8 0 0 0 1 $EXTERNAL_IP true 0.8 0.99 inference-perf-qwen-llm-d-comparison-final-179 0 0 true"


)

DEPLOYMENT_NAME="vllm-llama3-8b-instruct-epp"
export PREDICTED_LATENCY_PARAMS="" 

for scenario in "${SCENARIOS[@]}"; do
    set -- $scenario
    
    RUN_NAME=$1
    export WEIGHT_PREFIX_CACHE=$2
    export WEIGHT_QUEUE=$3
    export WEIGHT_KV_UTIL=$4
    export WEIGHT_PREDICTED_LATENCY=$5
    export BASE_URL=$6
    SKIP_CONFIG=$7
    export AFFINITY_GATE_TAU=$8
    export AFFINITY_GATE_TAU_GLOBAL=$9
    
    # 10th parameter: Renamed from PATH to OUTPUT_DIR to avoid crashing bash
    export OUTPUT_DIR=${10} 
    export SLO_ITL_MS=${11}
    export SLO_TTFT_MS=${12}
    export STREAMING_MODE=${13}

    export SUFFIX=$(date +%s)
    export REPORT_PREFIX="${RUN_NAME}"

    echo "################################################################"
    echo "STARTING SCENARIO: $RUN_NAME"
    echo "Target: $BASE_URL | Dir: $OUTPUT_DIR"
    if [ "$SKIP_CONFIG" = "false" ]; then
       echo "Weights -> Prefix: $WEIGHT_PREFIX_CACHE | Queue: $WEIGHT_QUEUE | KV: $WEIGHT_KV_UTIL | Pred: $WEIGHT_PREDICTED_LATENCY"
    fi
    echo "################################################################"
    
    # --- PHASE 1: RECONFIGURE SERVER ---
    if [ "$SKIP_CONFIG" = "false" ]; then
        echo "[1/4] Applying new EndpointPickerConfig..."
        envsubst < server-config.yaml | kubectl apply -f -
        
        echo "[2/4] Restarting Deployment ($DEPLOYMENT_NAME)..."
        kubectl rollout restart deployment/$DEPLOYMENT_NAME
        kubectl rollout status deployment/$DEPLOYMENT_NAME --timeout=10m
        
        echo "      Waiting 30s for endpoints to stabilize..."
        sleep 30
    else
        echo "[SKIP] Skipping server configuration and restart."
    fi

    # --- PHASE 2: EXECUTE BENCHMARK ---
    echo "[3/4] Submitting Benchmark Job..."
    # Ensure bench-job.yaml uses $OUTPUT_DIR instead of $PATH
    envsubst < bench-job.yaml | kubectl apply -f -

    echo "      Waiting for completion (inference-perf-$SUFFIX)..."
    kubectl wait --for=condition=complete job/inference-perf-$SUFFIX --timeout=2h

    # --- PHASE 3: CLEANUP ---
    echo "[4/4] Cleaning up..."
    kubectl delete job inference-perf-$SUFFIX
    kubectl delete configmap inference-perf-config-$SUFFIX

    echo "Finished $RUN_NAME."
    sleep 5
done
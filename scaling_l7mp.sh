#!/bin/bash

num_of_workers=0
pod_name_to_delete=''
pod_name_number=0
last_scale_num=1
declare -a array_of_pods
declare -a array_of_deleted_pods
csv='"time","worker-0","worker-1","worker-2","worker-3","worker-4","worker-5","total_num_of_calls"'
log_array=("worker-0" "worker-1" "worker-2" "worker-4" "worker-5" "worker-6")
start=$SECONDS

get_num_of_workers(){
    num_of_workers=`kubectl get pods --selector=app=l7mp-worker \
    -o go-template='{{range $index, $element := .items}} \ 
    {{range .status.containerStatuses}}{{if eq .name "l7mp"}}{{if .ready}} \ 
    {{$element.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}' | grep worker -c`
}

scale_up(){
    desired_num_instances=$1
    get_num_of_workers
    last_scale_num=`echo $((num_of_workers + 1))`
    echo "latest scale num is $last_scale_num"
    num_of_workers_to_delete=$num_of_workers
    new_instances=`echo $((desired_num_instances - num_of_workers))`
    echo "Number of new worker instances required $new_instances"
    for (( i=1; i<=$new_instances; i++ ))
    do
        next_workers_num=`echo $((num_of_workers + pod_name_number))`
        ((pod_name_number+=1))
        # echo "creating worker-$next_workers_num"
        sed -i "s/name: worker.*/name: worker-${next_workers_num}/g" ../controller_resources/l7mp/scaling_offload/resources/worker.yaml &&
        kubectl apply -f ../controller_resources/l7mp/scaling_offload/resources/worker.yaml &&
        sed -i "s/name: worker.*/name: worker-0/g" ../controller_resources/l7mp/scaling_offload/resources/worker.yaml &
        sleep 0.5
    done 

    #comment the line below for wrong scaling
    delete_oldest_pod_in_cluster 20 $num_of_workers_to_delete &   
}

scale_down(){
    ((last_scale_num-=1))
    delete_oldest_pod_in_cluster 10 1
}

#this function gets and deletes the oldest worker instance in the cluster
delete_oldest_pod_in_cluster() {
    sleep $1
    head=$2
    declare -a temp

    temp=($(kubectl get pods --sort-by=.metadata.creationTimestamp --selector=app=l7mp-worker \
    -o go-template='{{range $index, $element := .items}} \ 
    {{range .status.containerStatuses}}{{if eq .name "l7mp"}}{{if .ready}} \ 
    {{$element.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}' --no-headers \
    | grep worker |head -n $head | awk '{print $1'}))

    kubectl get pods --sort-by=.metadata.creationTimestamp --selector=app=l7mp-worker \
    -o go-template='{{range $index, $element := .items}} \ 
    {{range .status.containerStatuses}}{{if eq .name "l7mp"}}{{if .ready}} \ 
    {{$element.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}' --no-headers \
    | grep worker |head -n $head | awk '{system("kubectl delete po --force --grace-period=0 " $1 " &")}' | echo "Deletion of $head worker(s) started"

    for i in "${temp[@]}"
    do
    array_of_deleted_pods+=("${i}")
    done
}

scaling(){
    while :
    do
        sleep 2
        get_num_of_workers
        #Change address if needed dione 10.0.1.2
        #num_of_calls=$((`curl -s 10.0.1.2:8080/metrics | grep 'listenerName="ingress-rt' -c ` / 4 ))
	num_of_calls=$((`curl -s 10.0.1.2:1234/api/v1/listeners | grep '"name": "ingress-rt' -c` / 4))
        echo "$num_of_calls call(s) are running on $num_of_workers worker(s)"
        if [ $num_of_calls -ge $((num_of_workers * 10)) ]
        then
            #if previous scaling has finished to prevent rescaling while workers are still in creation state
            if [ $num_of_workers -eq $last_scale_num ]
            then
                echo "scaling up"
                scale_up $((num_of_workers + num_of_workers + 1)) 
            fi

        elif [ $num_of_calls -lt $(((num_of_workers - 1) * 10)) ]
        then
	    echo "Should scale down if last scling has finished"
            if [ $num_of_workers -eq $last_scale_num ]
            then
                echo "scaling down"
                scale_down 
                echo "scaling down has finished"
            fi
        fi
        
    done
}


fetch_pod_array(){
    array_of_pods=($(kubectl get pods --sort-by=.metadata.creationTimestamp --selector=app=l7mp-worker \
    -o go-template='{{range $index, $element := .items}} \ 
    {{range .status.containerStatuses}}{{if eq .name "l7mp"}}{{if .ready}} \ 
    {{$element.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}' --no-headers \
    | grep worker | awk '{print $1}'))
}

fetch_sessions_total_from_rtpengine(){
    stats="\""$(( SECONDS - start ))"\""
    csv=$(<scaling.csv)
    for i in "${log_array[@]}"
    do
    sleep 0
    call_num=$((`kubectl exec "$i" -c net-debug 2>&1 --  curl -s 127.0.0.1:1234/api/v1/sessions | grep '"name": "JSONSocket:worker-rt' -c` /4 ))
    stats="$stats"",\"""$call_num""\""
    done
    nc=$((`curl -s 10.0.1.2:1234/api/v1/listeners | grep '"name": "ingress-rt' -c` / 4))
    csv="$csv"$'\n'"$stats"",\"""$nc""\""
    echo "$csv"
    echo "$csv" > "./scaling.csv"
}

logging(){
    echo "$csv" > "./scaling.csv"
    while :
    do
        fetch_pod_array
        fetch_sessions_total_from_rtpengine
        sleep 3
    done
}


scaling & 
logging

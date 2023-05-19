#!/bin/bash
# set -x

DTRACK_URL=$1
DTRACK_KEY=$2
LANGUAGE=$3
DELETE=$4

FAIL_ON_CRITICAL=$5
FAIL_ON_HIGH=$6

INSECURE="--insecure"
#VERBOSE="--verbose"

# Access directory where GitHub will mount the repository code
# $GITHUB_ variables are directly accessible in the script
cd $GITHUB_WORKSPACE

# Run check for delete variable first so that install doesn't need to be run
PROJECT=$(curl -X GET -G --data-urlencode "name=$GITHUB_REPOSITORY"  \
                         --data-urlencode "version=$GITHUB_SHA" \
                         "$DTRACK_URL/api/v1/project/lookup" -H  "accept: application/json" -H  "X-Api-Key: $DTRACK_KEY")
PROJECT_EXISTS=$(echo $PROJECT | jq ".active")
if [[ -n "$PROJECT_EXISTS" ]]; then
    PROJECT_UUID=$(echo $PROJECT | jq -r ".uuid")
else
    PROJECT_UUID=$(curl \
        -d "{  \"name\": \"$GITHUB_REPOSITORY\",  \"version\": \"$GITHUB_SHA\"}" \
        -X PUT "$DTRACK_URL/api/v1/project" \
        -H  "accept: application/json" \
        -H  "Content-Type: application/json" \
        -H  "X-Api-Key: $DTRACK_KEY" | jq -r ".uuid"
    )
fi


if [[ $DELETE == "true" ]]; then
    DELETE_CODE=$(curl -X DELETE --head -w "%{http_code}" "$DTRACK_URL/api/v1/project/$PROJECT_UUID" -H  "accept: application/json" -H  "X-Api-Key: $DTRACK_KEY")
    echo "DELETE_CODE is $DELETE_CODE"
    if [[ $DELETE_CODE == "HTTP/2 204" ]]; then
        exit 0
    else
        echo $PROJECT
        echo $PROJECT_EXISTS
        echo $GITHUB_HEAD_REF
        echo $PROJECT_UUID
        exit 1
    fi
fi

case $LANGUAGE in
    "nodejs")
        lscommand=$(ls)
        echo "[*] Processing NodeJS BoM"
        apt-get install --no-install-recommends -y nodejs
        export NVM_DIR="$HOME/.nvm" && (
        git clone https://github.com/nvm-sh/nvm.git "$NVM_DIR"
        cd "$NVM_DIR"
        git checkout `git describe --abbrev=0 --tags --match "v[0-9]*" $(git rev-list --tags --max-count=1)`
        ) && \. "$NVM_DIR/nvm.sh"
        grep -q 12 ".nvmrc"
        if [[ $? != 0 && -f ".nvmrc" ]];
        then
            echo "Using .nvmrc file"
            nvm install
            nvm use
        else
            echo "Installing 16.14.2"
            nvm install 16.14.2
            nvm alias default 16.14.2
            nvm use default
        fi
        npm install
        npm audit fix --force --production
        if [ ! $? = 0 ]; then
            echo "[-] Error executing npm install. Stopping the action!"
            exit 1
        fi
        npm install -g @cyclonedx/cyclonedx-npm
        path="bom.xml"
        cyclonedx-npm --help
        BoMResult=$(cyclonedx-npm --output-format XML --ignore-npm-errors --short-PURLs --output-file bom.xml)
        ;;

    "python")
        echo "[*]  Processing Python BoM"
        apt-get install --no-install-recommends -y python3 python3-pip
        freeze=$(pip freeze > requirements.txt)
        if [ ! $? = 0 ]; then
            echo "[-] Error executing pip freeze to get a requirements.txt with frozen parameters. Stopping the action!"
            exit 1
        fi
        pip install cyclonedx-bom
        path="bom.xml"
        BoMResult=$(cyclonedx-py -o bom.xml)
        ;;

    "golang")
        echo "[*]  Processing Golang BoM"
        if [ ! $? = 0 ]; then
            echo "[-] Error executing go build. Stopping the action!"
            exit 1
        fi

        # Use main branch for now
        pwd
        go env GOPATH
        go get github.com/CycloneDX/cyclonedx-gomod/cmd/cyclonedx-gomod@latest && cp ~/go/bin/cyclonedx-gomod /usr/bin/

        path="bom.xml"
        BoMResult=$(cyclonedx-go -o bom.xml)
        ;;

    "java")
        echo "[*]  Processing Java BoM"
        if [ ! $? = 0 ]; then
            echo "[-] Error executing Java build. Stopping the action!"
            exit 1
        fi
        apt-get install --no-install-recommends -y build-essential default-jdk maven
        path="target/bom.xml"
        BoMResult=$(mvn compile)
        ;;

    *)
        "[-] Project type not supported: $LANGUAGE"
        exit 1
        ;;
esac

baseline_project=$(curl  $INSECURE $VERBOSE -s --location --request GET -G "$DTRACK_URL/api/v1/metrics/project/$PROJECT_UUID/current" \
    --header "X-Api-Key: $DTRACK_KEY")

baseline_score=$(echo $baseline_project | jq ".inheritedRiskScore" 2>/dev/nulll)

echo "[*] BoM file succesfully generated"

# Cyclonedx CLI conversion
echo "[*] Cyclonedx CLI conversion"

# UPLOAD BoM to Dependency track server
# TODO: Note autoCreate requires appropriate permissions and create variable
echo "[*] Uploading BoM file to Dependency Track server"
upload_bom=$(curl $INSECURE $VERBOSE -s --location --request POST $DTRACK_URL/api/v1/bom \
--header "X-Api-Key: $DTRACK_KEY" \
--header "Content-Type: multipart/form-data" \
--form "autoCreate=true" \
--form "projectName=$GITHUB_REPOSITORY" \
--form "projectVersion=$GITHUB_SHA" \
--form "bom=@bom.xml")


token=$(echo $upload_bom | jq ".token" | tr -d "\"")
echo "[*] BoM file succesfully uploaded with token $token"


if [ -z $token ]; then
    echo "[-]  The BoM file has not been successfully processed by OWASP Dependency Track"
    exit 1
fi

echo "[*] Checking BoM processing status"
processing=$(curl $INSECURE $VERBOSE -s --location --request GET $DTRACK_URL/api/v1/bom/token/$token \
--header "X-Api-Key: $DTRACK_KEY" | jq '.processing')


while [ $processing = true ]; do
    sleep 5
    processing=$(curl  $INSECURE $VERBOSE -s --location --request GET $DTRACK_URL/api/v1/bom/token/$token \
--header "X-Api-Key: $DTRACK_KEY" | jq '.processing')
    if [ $((++c)) -eq 50 ]; then
        echo "[-]  Timeout while waiting for processing result. Please check the OWASP Dependency Track status."
        exit 1
    fi
done

echo "[*] OWASP Dependency Track processing completed"

# wait to make sure the score is available, some errors found during tests w/o this wait
echo "[*] Waiting to allow score generation"
sleep 60

echo "[*] Retrieving project information"
project=$(curl  $INSECURE $VERBOSE -s --location --request GET "$DTRACK_URL/api/v1/project/lookup?name=$GITHUB_REPOSITORY&version=$GITHUB_SHA" \
--header "X-Api-Key: $DTRACK_KEY")

echo "-----PROJECT-------"
echo $project
echo "-------------------------"

if [[ -n "$baseline_score" ]]; then
    echo "Previous score was: $baseline_score"
    echo "baselinescore=$baseline_score" >> $GITHUB_OUTPUT
    previous_critical=$(echo $baseline_project | jq ".critical")
    previous_high=$(echo $baseline_project | jq ".high")
    previous_medium=$(echo $baseline_project | jq ".medium")
    previous_low=$(echo $baseline_project | jq ".low")
    previous_unassigned=$(echo $baseline_project | jq ".unassigned")
fi

project_metrics=$(curl  $INSECURE $VERBOSE -s --location --request GET -G "$DTRACK_URL/api/v1/metrics/project/$PROJECT_UUID/current" \
                    --header "X-Api-Key: $DTRACK_KEY")
project_uuid=$(echo $project | jq ".uuid" | tr -d "\"")
risk_score=$(echo $project | jq ".lastInheritedRiskScore")
critical=$(echo $project_metrics | jq ".critical")
high=$(echo $project_metrics | jq ".high")
medium=$(echo $project_metrics | jq ".medium")
low=$(echo $project_metrics | jq ".low")
unassigned=$(echo $project_metrics | jq ".unassigned")

echo "-----PROJECT METRICS-----"
echo $project_metrics
echo "-------------------------"

echo "riskscore=$risk_score" >> $GITHUB_OUTPUT
echo "critical=$critical" >> $GITHUB_OUTPUT
echo "high=$high" >> $GITHUB_OUTPUT
echo "medium=$medium" >> $GITHUB_OUTPUT
echo "low=$low" >> $GITHUB_OUTPUT
echo "unassigned=$unassigned" >> $GITHUB_OUTPUT
echo "previouscritical=$previous_critical" >> $GITHUB_OUTPUT
echo "previoushigh=$previous_high" >> $GITHUB_OUTPUT
echo "previousmedium=$previous_medium" >> $GITHUB_OUTPUT
echo "previouslow=$previous_low" >> $GITHUB_OUTPUT
echo "previousunassigned=$previous_unassigned" >> $GITHUB_OUTPUT
echo "project_url=$DTRACK_URL/projects/$PROJECT_UUID" >> $GITHUB_OUTPUT
echo "fail_on_critical=$FAIL_ON_CRITICAL" >> $GITHUB_OUTPUT
echo "fail_on_high=$FAIL_ON_HIGH" >> $GITHUB_OUTPUT

cat $GITHUB_OUTPUT
if [[ $critical -gt 0 ]] && [[ $FAIL_ON_CRITICAL == "true" ]];
then
    echo 'Failing due to presence of criticals'
    exit 1
fi

if [[ $high -gt 0 ]] && [[ $FAIL_ON_HIGH == "true" ]];
then
    echo 'Failing due to presence of highs'
    exit 1
fi

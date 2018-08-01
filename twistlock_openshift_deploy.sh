#!/bin/bash

# Constants
TWISTLOCK_PUBLIC_REGISTRY="registry.twistlock.com"
TWISTLOCK_VERSION="2_4_95"
TWISTLOCK_RELEASE_URL="https://twistlock.example.com/releases/twistlock_2_4_95.tar.gz"

# validate user is logged in with OC Client
if ! oc version | grep Server > /dev/null; then
  echo "You must be logged into the oc Client."
  echo "Please run the oc login command from the OpenShift Web Console."
  echo "Twistlock not installed."
  exit 1
fi

# validate script is being run on MacOS or Linux
uname=$(uname -s)
if [ "$uname" = "Darwin" ]; then
  echo "Found to be running script from a Mac.."
  machine="osx"
elif [ "$uname" = "Linux" ]; then
  echo "Found to be running script from a Linux machine.."
  machine="linux"
else
  echo "This script can only be run on Linux or Mac"
  exit 1
fi

# namespace to deploy twistlock resources to 
echo -n "Enter Twistlock Namespace: "
read TWISTLOCK_NAMESPACE

# store Twistlock access token for API authentication
echo -n "Enter Twistlock Access Token: "
read -s ACCESS_TOKEN
echo 

# store Twistlock license
echo -n "Enter Twistlock License Key: "
read -s TWISTLOCK_LICENSE
echo

# define twistlock console route
echo -n "Enter Twistlock External Route: "
read TWISTLOCK_EXTERNAL_ROUTE

# define twistlock admin user/pass
echo -n "Enter Twistlock Console Admin User: "
read TWISTLOCK_CONSOLE_USER

echo -n "Enter Twistlock Console Password: "
read -s TWISTLOCK_CONSOLE_PASSWORD
echo

# validate route docker-registry exists in the default namespace
if ! oc get route docker-registry -n default; then
  echo "Error: route docker-registry not found in default namespace"
  exit 1
fi

IMAGE_REGISTRY_EXTERNAL=$(oc get route docker-registry -n default | awk '{print $2}' | tail -n +2)
IMAGE_REGISTRY_INTERNAL="docker-registry.default.svc:5000"
IMAGE_REGISTRY_ADDRESS="$IMAGE_REGISTRY_INTERNAL/twistlock/private:console_$TWISTLOCK_VERSION"

# create twistlock namespace
echo "Creating new project: $TWISTLOCK_NAMESPACE"
if ! oc adm new-project $TWISTLOCK_NAMESPACE --node-selector=''; then
  echo "Failed to create project $TWISTLOCK_NAMESPACE"
  echo "Exiting.."
  exit 1
fi

# pull twistlock console image
echo "Retrieving console image from: $TWISTLOCK_PUBLIC_REGISTRY/twistlock/console:console_$TWISTLOCK_VERSION"
if ! docker login -u twistlock -p $(echo $ACCESS_TOKEN | tr '[:upper:]' '[:lower:]') $TWISTLOCK_PUBLIC_REGISTRY | grep "Login Succeeded"; then
    echo "Error logging into the Twistlock Registry: $TWISTLOCK_PUBLIC_REGISTRY"
    exit 1
fi
docker pull $TWISTLOCK_PUBLIC_REGISTRY/twistlock/console:console_$TWISTLOCK_VERSION
docker pull $TWISTLOCK_PUBLIC_REGISTRY/twistlock/defender:defender_$TWISTLOCK_VERSION

if ! docker login -u $(oc whoami) -p $(oc whoami -t) $IMAGE_REGISTRY_EXTERNAL | grep "Login Succeeded"; then
  echo "Error logging into the OpenShift Registry"
  exit 1
fi
echo "Pushing console image to: $IMAGE_REGISTRY_EXTERNAL/twistlock/private:console_$TWISTLOCK_VERSION"
docker tag $TWISTLOCK_PUBLIC_REGISTRY/twistlock/console:console_$TWISTLOCK_VERSION $IMAGE_REGISTRY_EXTERNAL/twistlock/private:console_$TWISTLOCK_VERSION
docker push $IMAGE_REGISTRY_EXTERNAL/twistlock/private:console_$TWISTLOCK_VERSION

echo "Pushing defender image to $IMAGE_REGISTRY_EXTERNAL/$TWISTLOCK_NAMESPACE/private:defender_$TWISTLOCK_VERSION"
docker tag $TWISTLOCK_PUBLIC_REGISTRY/twistlock/defender:defender_$TWISTLOCK_VERSION $IMAGE_REGISTRY_EXTERNAL/$TWISTLOCK_NAMESPACE/private:defender_$TWISTLOCK_VERSION
docker push $IMAGE_REGISTRY_EXTERNAL/$TWISTLOCK_NAMESPACE/private:defender_$TWISTLOCK_VERSION

# Retrieve the Twistlock release
echo "Retrieiving Twistlock Release.."
if ! wget --no-check-certificate -O twistlock.tar.gz $TWISTLOCK_RELEASE_URL; then
  echo "Error Retrieving Twistlock Release: $TWISTLOCK_RELEASE_URL"
  exit 1
fi
tar -xzf twistlock.tar.gz

# Deploy the Twistlock console
# let user give PV labels or select a storage class
echo "Select storage for Twistlock console"
options=("Persistent Volume Labels" "Storage Class" "Quit")
select opt in "${options[@]}"
do
  case $opt in
    "Persistent Volume Labels")
      echo "you chose Persistent Volume Labels"
      echo -n "Enter PV Labels: "
      read PV_LABELS
      [[ -z "${PV_LABELS}" ]] && PV_LABELS='" "'

      # Deploy the Twistlock console
      $machine/twistcli console install \
      --namespace "$TWISTLOCK_NAMESPACE" \
      --orchestration-type "openshift" \
      --orchestration-cli "oc" \
      --registry-address "$IMAGE_REGISTRY_ADDRESS" \
      --registry-client "docker" \
      --skip-push \
      --persistent-volume-labels "$PV_LABELS" \
      --verbose && break || echo "Error creating twistlock console" && exit 1
      
      ;;
    "Storage Class")
      echo "you chose storage class"
      echo "Select storage class"
      options=($(oc get sc -o name | sed "s/storageclasses\///g" | tr '\r\n' ' ') "Quit")
      select sc in "${options[@]}"
      do
        case $sc in 
          "Quit")
            echo "exiting"
            exit 1;;
          * )
            if [[ -z "${opt}" ]]; then
              echo "invalid option"
            else
              echo "you chose $opt"
              EXIT_SC=1
             fi
             [[ ! -z "${EXIT_SC}" ]] && \
             $machine/twistcli console install \
             --namespace "$TWISTLOCK_NAMESPACE" \
             --orchestration-type "openshift" \
             --orchestration-cli "oc" \
             --registry-address "$IMAGE_REGISTRY_ADDRESS" \
             --registry-client "docker" \
             --skip-push \
             --storage-class $sc \
             --verbose && break || echo "Error creating twistlock console" && exit 1
             ;; 
        esac
      done
      break;;
    "Quit")
      echo "exiting" 
      exit 1;;
    * ) 
      echo "invalid option";;
  esac 
done

# wait for Twistlock Console to be ready
n=0
console_ready=0
until [ $n -ge 6 ]; do
    if oc get pods -n $TWISTLOCK_NAMESPACE | grep twistlock-console | grep Running; then 
      console_ready=1
      break 
    fi
    n=$[$n+1]
    echo "Waiting for twistlock console to be ready ($n/6)"
    sleep 10
done
if [ $console_ready -eq 0 ]; then
  echo "Twistlock Console did not start in time."
  exit 1
fi

# create Twistlock Console route
cat > twistlock_external_route.yaml <<EOL
apiVersion: v1
kind: Route
metadata:
  namespace: $TWISTLOCK_NAMESPACE
  labels:
    name: console
  name: twistlock-console
spec:
  host: $TWISTLOCK_EXTERNAL_ROUTE
  port:
    targetPort: mgmt-http
  tls:
    insecureEdgeTerminationPolicy: Redirect
    termination: edge
  to:
    kind: Service
    name: twistlock-console
    weight: 100
  wildcardPolicy: None
EOL

oc apply -f twistlock_external_route.yaml

# wait for console to be ready to serve endpoints
sleep 5

# set Twistlock console user/pass
if ! curl -k -H 'Content-Type: application/json' -X POST \
     -d "{\"username\": \"$TWISTLOCK_CONSOLE_USER\", \"password\": \"$TWISTLOCK_CONSOLE_PASSWORD\"}" \
     https://$TWISTLOCK_EXTERNAL_ROUTE/api/v1/signup; then

    echo "Error creating Twistlock Console user $TWISTLOCK_CONSOLE_USER"
    exit 1
fi

# Set Twistlock license. Using default user/pass
if ! curl -k \
  -u $TWISTLOCK_CONSOLE_USER:$TWISTLOCK_CONSOLE_PASSWORD \
  -H 'Content-Type: application/json' \
  -X POST \
  -d "{\"key\": \"$TWISTLOCK_LICENSE\"}" \
  https://$TWISTLOCK_EXTERNAL_ROUTE/api/v1/settings/license; then 

    echo "Error uploading Twistlock license to console"
    exit 1
fi

# deploy the defenders
daemonset_file=$($machine/twistcli defender export daemonset \
  --address https://$TWISTLOCK_EXTERNAL_ROUTE \
  --cluster-address $(oc get service twistlock-console -n $TWISTLOCK_NAMESPACE | awk '{print $2}' | tail -n +2) \
  --namespace $TWISTLOCK_NAMESPACE \
  --orchestration-type openshift \
  --user $TWISTLOCK_CONSOLE_USER \
  --password $TWISTLOCK_CONSOLE_PASSWORD \
  --registry-client $IMAGE_REGISTRY_INTERNAL | grep "Daemonset" | awk '{print $5}')
  
oc apply -f $daemonset_file

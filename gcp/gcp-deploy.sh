while [[ "$#" -gt 0 ]]; do
    case $1 in
        --region) GCP_REGION="$2"; shift ;;
        --firestore-region) FIRESTORE_REGION="$2"; shift ;;
        --newrelic-account-id) NEWRELIC_ACCOUNT_ID="$2"; shift ;;
        --firebase-credentials-path) FIREBASE_CREDENTIALS_PATH="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ -z "$GCP_REGION" ]; then
    echo "Error: Missing --region argument."
    exit 1
fi

if [ -z "$FIRESTORE_REGION" ]; then
    echo "Error: Missing --firestore-region argument."
    exit 1
fi

if [ -z "$FIREBASE_CREDENTIALS_PATH" ]; then
    echo "Error: Missing --firebase-credentials-path argument."
    exit 1
fi

CLUSTER_NAME="disto-cluster"
GCP_PROJECT_ID="disto-project-id"
GCS_BUCKET_NAME="disto-bucket"
SERVICE_ACCOUNT_EMAIL="disto-service-account@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
SERVICE_ACCOUNT_NAME=disto-service-account
SERVICE_ACCOUNT_DISPLAY_NAME="Disto Service Account"

# Create a project with a specified name and ID
echo "Creating Disto project"
gcloud projects create $GCP_PROJECT_ID --name=disto
echo "Done creating Disto project"

# Create a GCS bucket in a specified region
echo "Creating Disto GCS bucket"
gcloud storage buckets create gs://$GCS_BUCKET_NAME --location=$GCP_REGION --project=$GCP_PROJECT_ID
echo "Done creating Disto GCS bucket"

# create firestore db
echo "Creating Disto firestore DB"
gcloud services enable firestore.googleapis.com --project=$GCP_PROJECT_ID

gcloud firestore databases create --location=$FIRESTORE_REGION --project=$GCP_PROJECT_ID

# enable secrets manager
echo "Enabling secrets manager"
gcloud services enable secretmanager.googleapis.com --project=$GCP_PROJECT_ID

echo "Enabling Vertex AI API"
gcloud services enable aiplatform.googleapis.com --project=$GCP_PROJECT_ID

# Extract values from the Firebase credentials JSON file
FIREBASE_API_KEY=$(jq -r '.apiKey' $FIREBASE_CREDENTIALS_PATH)
FIREBASE_AUTH_DOMAIN=$(jq -r '.authDomain' $FIREBASE_CREDENTIALS_PATH)
FIREBASE_PROJECT_ID=$(jq -r '.projectId' $FIREBASE_CREDENTIALS_PATH)
FIREBASE_STORAGE_BUCKET=$(jq -r '.storageBucket' $FIREBASE_CREDENTIALS_PATH)
FIREBASE_MESSAGING_SENDER_ID=$(jq -r '.messagingSenderId' $FIREBASE_CREDENTIALS_PATH)
FIREBASE_APP_ID=$(jq -r '.appId' $FIREBASE_CREDENTIALS_PATH)

# create new service account for disto
echo "Creating Disto service account"

gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME --display-name="${SERVICE_ACCOUNT_DISPLAY_NAME}" --project=${GCP_PROJECT_ID}

gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/storage.objectAdmin"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/container.developer"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/editor"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/secretmanager.secretAccessor"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/secretmanager.secretVersionAdder"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/secretmanager.secretVersionManager"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/iam.workloadIdentityUser"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/iam.serviceAccountTokenCreator"

echo "Done creating Disto service account"

echo "Creating cluster ..."
gcloud services enable container.googleapis.com --project=${GCP_PROJECT_ID}

gcloud container clusters create-auto ${CLUSTER_NAME} \
    --location=$GCP_REGION \
    --project=${GCP_PROJECT_ID}

gcloud container clusters get-credentials ${CLUSTER_NAME} --zone $GCP_REGION --project=${GCP_PROJECT_ID}
echo "Done creating cluster"

# associate Kubernetes service account with google cloud service account
echo "Associating Kubernetes service account with Disto service account"
gcloud container clusters update ${CLUSTER_NAME} \
    --workload-pool=${GCP_PROJECT_ID}.svc.id.goog \
    --location=$GCP_REGION \
    --project=${GCP_PROJECT_ID}

kubectl annotate serviceaccount \
  --namespace default \
  default \
  iam.gke.io/gcp-service-account=${SERVICE_ACCOUNT_EMAIL}

gcloud iam service-accounts add-iam-policy-binding ${SERVICE_ACCOUNT_EMAIL} \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${GCP_PROJECT_ID}.svc.id.goog[default/default]" \
  --project=${GCP_PROJECT_ID}

echo "Deploying Nginx Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.0.4/deploy/static/provider/cloud/deploy.yaml
sleep 120 # This waits for 2 minutes. Adjust as needed.
echo "Done deploying Nginx Ingress Controller"

echo "Creating configmap ..."
kubectl create configmap flask-config \
--from-literal=PALM_MODEL_NAME=chat-bison@001 \
--from-literal=GITHUB_APP_ID=292639 \
--from-literal=USE_GKE_GCLOUD_AUTH_PLUGIN=True \
--from-literal=GCP_REGION=$GCP_REGION \
--from-literal=GCS_BUCKET_NAME=$GCS_BUCKET_NAME \
--from-literal=NEWRELIC_ACCOUNT_ID=$NEWRELIC_ACCOUNT_ID \
--from-literal=GCP_PROJECT_ID=$GCP_PROJECT_ID \
--from-literal=FIREBASE_API_KEY=$FIREBASE_API_KEY \
--from-literal=FIREBASE_AUTH_DOMAIN=$FIREBASE_AUTH_DOMAIN \
--from-literal=FIREBASE_PROJECT_ID=$FIREBASE_PROJECT_ID \
--from-literal=FIREBASE_STORAGE_BUCKET=$FIREBASE_STORAGE_BUCKET \
--from-literal=FIREBASE_MESSAGING_SENDER_ID=$FIREBASE_MESSAGING_SENDER_ID \
--from-literal=FIREBASE_APP_ID=$FIREBASE_APP_ID

echo "Done creating configmap"

# Step 3: Apply the deployment YAML
echo "Deploying containers ..."
kubectl apply -f deploy.yaml
echo "Done deploying containers"

# Wait for services to get external IPs. This can take a few minutes.
echo "Waiting for services to get external IPs..."
sleep 120 # This waits for 2 minutes. Adjust as needed.

# Print the URLs of the frontend and backend services
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "Access services via: http://$INGRESS_IP"

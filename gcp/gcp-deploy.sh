while [[ "$#" -gt 0 ]]; do
    case $1 in
        --region) GCP_REGION="$2"; shift ;;
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

if [ -z "$FIREBASE_CREDENTIALS_PATH" ]; then
    echo "Error: Missing --firebase-credentials-path argument."
    exit 1
fi


GCP_PROJECT_ID="disto-project-id"
GCS_BUCKET_NAME="disto-bucket"
GOOGLE_CREDENTIALS_PATH="disto-service-account-key.json"
SERVICE_ACCOUNT_EMAIL="disto-service-account@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
SERVICE_ACCOUNT_NAME=disto-service-account
SERVICE_ACCOUNT_DISPLAY_NAME="Disto Service Account"

# Create a project with a specified name and ID
echo "Creating Disto project"
gcloud projects create $GCP_PROJECT_ID --name=disto
echo "Done creating Disto project"

# capture original project ID
ORIGINAL_PROJECT_ID=$(gcloud config get-value project)

# Set the project
#echo "Setting gcloud to Disto project ID: $GCP_PROJECT_ID"
#gcloud config set project $GCP_PROJECT_ID

# Create a GCS bucket in a specified region
echo "Creating Disto GCS bucket"
gcloud storage buckets create gs://$GCS_BUCKET_NAME --location=$GCP_REGION
echo "Done creating Disto GCS bucket"

# create firestore db
echo "Creating Disto firestore DB"
gcloud services enable firestore.googleapis.com


# Check if Firestore is initialized (this is a basic check and might not cover all edge cases)
if ! gcloud firestore databases list --project=$GCP_PROJECT_ID | grep -q $DATABASE_ID; then
    # Create Firestore database if not initialized
    gcloud firestore databases create --region=$GCP_REGION
else
    echo "Firestore is already initialized."
fi
echo "Done creating Disto firestore DB"

# enable secrets manager
echo "Enabling secrets manager"
gcloud services enable secretmanager.googleapis.com

# create new service account for disto
echo "Creating Disto service account"

gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME --display-name${SERVICE_ACCOUNT_DISPLAY_NAME} --project=${GCP_PROJECT_ID}

gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/owner"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/storage.admin"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/container.admin"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/datastore.owner"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/secretmanager.admin"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/secretmanager.secretAccessor"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/iam.workloadIdentityUser"
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" --role="roles/iam.serviceAccountTokenCreator"

gcloud iam service-accounts keys create $GOOGLE_CREDENTIALS_PATH --iam-account=${SERVICE_ACCOUNT_EMAIL}

# associate Kubernetes service account with google cloud service account
echo "Associating Kubernetes service account with Disto service account"
kubectl annotate serviceaccount \
  --namespace default \
  default \
  iam.gke.io/gcp-service-account=${SERVICE_ACCOUNT_EMAIL}

gcloud iam service-accounts add-iam-policy-binding \                                         
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:forward-ace-395519.svc.id.goog[default/default]" \
  407653381674-compute@developer.gserviceaccount.com

echo "Done creating Disto service account"

# Extract values from the Google credentials JSON file
GCP_CREDENTIALS_PROJECT_ID=$(jq -r '.project_id' $GOOGLE_CREDENTIALS_PATH)
GCP_CREDENTIALS_PRIVATE_KEY_ID=$(jq -r '.private_key_id' $GOOGLE_CREDENTIALS_PATH)
GCP_CREDENTIALS_PRIVATE_KEY=$(jq -r '.private_key' $GOOGLE_CREDENTIALS_PATH)
GCP_CREDENTIALS_CLIENT_EMAIL=$(jq -r '.client_email' $GOOGLE_CREDENTIALS_PATH)
GCP_CREDENTIALS_CLIENT_ID=$(jq -r '.client_id' $GOOGLE_CREDENTIALS_PATH)
GCP_CREDENTIALS_AUTH_URI=$(jq -r '.auth_uri' $GOOGLE_CREDENTIALS_PATH)
GCP_CREDENTIALS_TOKEN_URI=$(jq -r '.token_uri' $GOOGLE_CREDENTIALS_PATH)
GCP_CREDENTIALS_AUTH_PROVIDER_URL=$(jq -r '.auth_provider_x509_cert_url' $GOOGLE_CREDENTIALS_PATH)
GCP_CREDENTIALS_CLIENT_CERT_URL=$(jq -r '.client_x509_cert_url' $GOOGLE_CREDENTIALS_PATH)


# Extract values from the Firebase credentials JSON file
FIREBASE_API_KEY=$(jq -r '.apiKey' $FIREBASE_CREDENTIALS_PATH)
FIREBASE_AUTH_DOMAIN=$(jq -r '.authDomain' $FIREBASE_CREDENTIALS_PATH)
FIREBASE_PROJECT_ID=$(jq -r '.projectId' $FIREBASE_CREDENTIALS_PATH)
FIREBASE_STORAGE_BUCKET=$(jq -r '.storageBucket' $FIREBASE_CREDENTIALS_PATH)
FIREBASE_MESSAGING_SENDER_ID=$(jq -r '.messagingSenderId' $FIREBASE_CREDENTIALS_PATH)
FIREBASE_APP_ID=$(jq -r '.appId' $FIREBASE_CREDENTIALS_PATH)


echo "Creating cluster ..."
gcloud container clusters create-auto disto-cluster \
    --location=$GCP_REGION
    --workload-pool=${GCP_PROJECT_ID}.svc.id.goog \


gcloud container clusters get-credentials disto-cluster --zone $GCP_REGION
echo "Done creating cluster"


echo "Deploying Nginx Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.0.4/deploy/static/provider/cloud/deploy.yaml
sleep 120 # This waits for 2 minutes. Adjust as needed.
echo "Done deploying Nginx Ingress Controller"

echo "Creating secrets ..."
kubectl create secret generic flask-secrets \
--from-literal=GCP_CREDENTIALS_PRIVATE_KEY="$GCP_CREDENTIALS_PRIVATE_KEY" \
--from-literal=GCP_CREDENTIALS_CLIENT_EMAIL=$GCP_CREDENTIALS_CLIENT_EMAIL
echo "Done creating secrets"

echo "Creating configmap ..."
kubectl create configmap flask-config \
--from-literal=PALM_MODEL_NAME=chat-bison@001 \
--from-literal=GITHUB_APP_ID=292639 \
--from-literal=USE_GKE_GCLOUD_AUTH_PLUGIN=True \
--from-literal=GCP_REGION=$GCP_REGION \
--from-literal=GCS_BUCKET_NAME=$GCS_BUCKET_NAME \
--from-literal=NEWRELIC_ACCOUNT_ID=$NEWRELIC_ACCOUNT_ID \
--from-literal=GCP_CREDENTIALS_PROJECT_ID=$GCP_CREDENTIALS_PROJECT_ID \
--from-literal=GCP_CREDENTIALS_PRIVATE_KEY_ID=$GCP_CREDENTIALS_PRIVATE_KEY_ID \
--from-literal=GCP_CREDENTIALS_CLIENT_ID=$GCP_CREDENTIALS_CLIENT_ID \
--from-literal=GCP_CREDENTIALS_AUTH_URI=$GCP_CREDENTIALS_AUTH_URI \
--from-literal=GCP_CREDENTIALS_TOKEN_URI=$GCP_CREDENTIALS_TOKEN_URI \
--from-literal=GCP_CREDENTIALS_AUTH_PROVIDER_URL=$GCP_CREDENTIALS_AUTH_PROVIDER_URL \
--from-literal=GCP_CREDENTIALS_CLIENT_CERT_URL=$GCP_CREDENTIALS_CLIENT_CERT_URL \
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

# set gcloud back to original project ID
#echo "Setting gcloud back to original project ID: $ORIGINAL_PROJECT_ID"
#gcloud config set project $ORIGINAL_PROJECT_ID

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --s3-bucket-name) S3_BUCKET_NAME="$2"; shift ;;
        --aws-region) AWS_REGION="$2"; shift ;;
        --cognito-user-pool-id) AWS_COGNITO_USER_POOL_ID="$2"; shift ;;
        --cognito-client-id) AWS_COGNITO_CLIENT_ID="$2"; shift ;;
        --sagemaker-endpoint-name) SAGEMAKER_ENDPOINT_NAME="$2"; shift ;;
        --sagemaker-region-name) SAGEMAKER_REGION_NAME="$2"; shift ;;
        --aws-access-key-id) AWS_ACCESS_KEY_ID="$2"; shift ;;
        --aws-secret-access-key) AWS_SECRET_ACCESS_KEY="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ -z "$S3_BUCKET_NAME" ]; then
    echo "Error: Missing --s3-bucket-name argument."
    exit 1
fi

if [ -z "$AWS_REGION" ]; then
    echo "Error: Missing --aws-region argument."
    exit 1
fi

if [ -z "$AWS_COGNITO_USER_POOL_ID" ]; then
    echo "Error: Missing --cognito-user-pool-id argument."
    exit 1
fi

if [ -z "$AWS_COGNITO_CLIENT_ID" ]; then
    echo "Error: Missing --cognito-client-id argument."
    exit 1
fi

if [ -z "$SAGEMAKER_ENDPOINT_NAME" ]; then
    echo "Error: Missing --sagemaker-endpoint-name argument."
    exit 1
fi

if [ -z "$SAGEMAKER_REGION_NAME" ]; then
    echo "Error: Missing --sagemaker-region-name argument."
    exit 1
fi

if [ -z "$AWS_ACCESS_KEY_ID" ]; then
    echo "Error: Missing --aws-access-key-id argument."
    exit 1
fi

if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Error: Missing --aws-secret-access-key argument."
    exit 1
fi


echo "Creating cluster ..."
eksctl create cluster --name disto-cluster --region $AWS_REGION
echo "Done creating cluster"

echo "Deploying Nginx Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.0.4/deploy/static/provider/aws/deploy.yaml
sleep 120 # This waits for 2 minutes. Adjust as needed.
echo "Done deploying Nginx Ingress Controller"

echo "Creating secrets ..."
kubectl create secret generic flask-secrets \
--from-literal=AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
--from-literal=AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
echo "Done creating secrets"

# Create a configMap for other environment variables
echo "Creating configmap ..."
kubectl create configmap flask-config \
--from-literal=GITHUB_APP_ID=292639 \
--from-literal=S3_BUCKET_NAME=$S3_BUCKET_NAME \
--from-literal=AWS_REGION=$AWS_REGION \
--from-literal=AWS_COGNITO_USER_POOL_ID=$AWS_COGNITO_USER_POOL_ID \
--from-literal=AWS_COGNITO_CLIENT_ID=$AWS_COGNITO_CLIENT_ID \
--from-literal=SAGEMAKER_ENDPOINT_NAME=$SAGEMAKER_ENDPOINT_NAME \
--from-literal=SAGEMAKER_REGION_NAME=$SAGEMAKER_REGION_NAME \

echo "Done creating configmap"

# Step 3: Apply the deployment YAML
echo "Deploying containers ..."
kubectl apply -f deploy.yaml
echo "Done deploying containers"

# Wait for services to get external hostnames. This can take a few minutes.
echo "Waiting for services to get external hostnames..."
sleep 120 # This waits for 2 minutes. Adjust as needed.

# Print the URLs of the frontend and backend services
INGRESS_HOSTNAME=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o=jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Access services via: http://$INGRESS_HOSTNAME"
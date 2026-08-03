ECR_REGISTRY="255748959698.dkr.ecr.us-east-1.amazonaws.com"
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_REGISTRY
docker build -t luzia .
docker tag luzia:latest $ECR_REGISTRY/luzia:latest
docker push $ECR_REGISTRY/luzia:latest

./build.sh
aws ecs update-service --cluster cluster-luzia --service service-luzia  --force-new-deployment

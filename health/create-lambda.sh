#!/bin/bash

# Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# 
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License is located at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# or in the "license" file accompanying this file. This file is distributed 
# on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either 
# express or implied. See the License for the specific language governing 
# permissions and limitations under the License.

# Uses SAM (serverless application model) to deploy the peer health check Lambda function

if [ -z "$NETWORKID" ]
then
      echo "Environment variables \$NETWORKID, \$MEMBERID or \$REGION are empty. Please see the pre-requisites in the README"
fi

if [ -z "$NETWORKNAME" ]
then
      echo "Environment variable \$NETWORKNAME is empty. Please see the pre-requisites in the README"
fi

if [ -z "$SNSEMAIL" ]
then
      echo "Environment variable \$SNSEMAIL is empty. Please see the pre-requisites in the README"
fi

echo Build the Lambda function and copy to S3
BUCKETNAME=`echo "$NETWORKNAME-peer-health" | tr '[:upper:]' '[:lower:]'`
aws s3 mb s3://$BUCKETNAME --region $REGION
cd peer-health
rm -rf node_modules
curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.33.0/install.sh | bash
. ~/.nvm/nvm.sh
nvm install lts/carbon
nvm use lts/carbon
npm install
cd ..
aws cloudformation package --template-file peer-health-template.yaml \
      --output-template-file packaged-peer-health-template.yaml \
      --s3-bucket $BUCKETNAME

echo Deploy the Lambda function
aws cloudformation deploy --template-file packaged-peer-health-template.yaml \
      --region $REGION --capabilities CAPABILITY_IAM \
      --stack-name $NETWORKNAME-peer-health-lambda \
      --parameter-overrides NetworkId=$NETWORKID NotificationEmail=$SNSEMAIL
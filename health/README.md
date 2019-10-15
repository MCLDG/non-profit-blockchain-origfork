# Health check the Managed Blockchain peer nodes

In this section we will deploy a Lambda function that checks the health of the Amazon Managed Blockchain peer nodes.
The Lambda function will return success if all the peer nodes in the Fabric network are AVAILABLE, otherwise it will
return an error.

## Pre-requisites

From Cloud9, SSH into the Fabric client node. The key (i.e. the .PEM file) should be in your home directory. 
The DNS of the Fabric client node EC2 instance can be found in the output of the AWS CloudFormation stack you 
created in [Part 1](../ngo-fabric/README.md)

```
ssh ec2-user@<dns of EC2 instance> -i ~/<Fabric network name>-keypair.pem
```

You should have already cloned this repo in [Part 1](../ngo-fabric/README.md)

```
cd ~
git clone https://github.com/aws-samples/non-profit-blockchain.git
```

You will need to set the context before carrying out any Fabric CLI commands. We do this 
using the export files that were generated for us in [Part 1](../ngo-fabric/README.md)

Source the file, so the exports are applied to your current session. If you exit the SSH 
session and re-connect, you'll need to source the file again. The `source` command below
will print out the values of the key ENV variables. Make sure they are all populated. If
they are not, follow Step 4 in [Part 1](../ngo-fabric/README.md) to repopulate them:

```
cd ~/non-profit-blockchain/ngo-fabric
source fabric-exports.sh
source ~/peer-exports.sh 
```

## Overview

The steps we will execute in this part are:

1. Create a staging folder for the Lambda deployment bundle
2. Copy the Managed Blockchain certificate
3. Create the Fabric user credentials
4. Put user credentials on Secrets Manager
5. Copy the Fabric client configuration files
6. Install the npm dependencies
7. Create the IAM role and policies
8. Create the Lambda function
9. Create a VPC Endpoint to Secrets Manager
10. Test the Lambda function

## Step 1 - Create a staging folder for the Lambda deployment bundle

Copy the source folder into a staging folder we can use for preparing the deployment bundle we will deploy to Lambda.

```
cp -R ~/non-profit-blockchain/health /tmp/lambdaWork
```

## Step 2 - Copy the Managed Blockchain certificate

Copy the latest version of the Managed Blockchain PEM file into the staging folder. This will be used to secure communication with the Managed Blockchain service.

```
cp ~/managedblockchain-tls-chain.pem /tmp/lambdaWork/certs/managedblockchain-tls-chain.pem
```

## Step 3 - Create the Fabric user credentials

Register and enroll an identity with the Fabric CA (certificate authority). We will use this identity within the Lambda function.  In the example below we are creating a user named `lambdaUser` with a password of `Welcome123`.  The password is optional and one will be generated if not provided.  The credentials will be written into `/tmp/certs/lambdaUser/keystore` and `/tmp/certs/lambdaUser/signcerts`.

```
export FABRICUSER=lambdaUser
export FABRICUSERPASSWORD=Welcome123
export PATH=$PATH:/home/ec2-user/go/src/github.com/hyperledger/fabric-ca/bin
cd ~
fabric-ca-client register --id.name $FABRICUSER --id.affiliation $MEMBERNAME --tls.certfiles ~/managedblockchain-tls-chain.pem --id.type user --id.secret $FABRICUSERPASSWORD
fabric-ca-client enroll -u https://$FABRICUSER:$FABRICUSERPASSWORD@$CASERVICEENDPOINT --tls.certfiles /home/ec2-user/managedblockchain-tls-chain.pem -M /tmp/certs/$FABRICUSER
```

## Step 4 - Put user credentials on Secrets Manager ##
```
aws secretsmanager create-secret --name "dev/fabricOrgs/$MEMBERNAME/$FABRICUSER/pk" --secret-string "`cat /tmp/certs/$FABRICUSER/keystore/*`" --region $REGION
aws secretsmanager create-secret --name "dev/fabricOrgs/$MEMBERNAME/$FABRICUSER/signcert" --secret-string "`cat /tmp/certs/$FABRICUSER/signcerts/*`" --region $REGION
```

## Step 5 - Copy the Fabric client connection profiles

You should have created the Fabric client configuration files in Part 3.  If not, follow the instructions in [Part 3 - Step 3](../ngo-rest-api/README.md) before continuing.  Make sure to source the files mentioned in the **Pre-requisites** section of Part 3 before generating the configuration files.

Once the configuration files have been created, copy them to the staging folder and update the path to the Managed Blockchain certificate.

```
cp ~/non-profit-blockchain/tmp/connection-profile/ngo-connection-profile.yaml /tmp/lambdaWork/.
cp ~/non-profit-blockchain/tmp/connection-profile/org1/client-org1.yaml /tmp/lambdaWork/.
sed -i "s|/home/ec2-user/managedblockchain-tls-chain.pem|./certs/managedblockchain-tls-chain.pem|g" /tmp/lambdaWork/ngo-connection-profile.yaml
```

## Step 6 - Install the npm dependencies

You should have already installed `nvm` in a prior step.  If not, follow the instructions in [Part 3 - Step 1](../ngo-rest-api/README.md) before continuing.  Be sure to install the `gcc` compiler in that step.

```
cd /tmp/lambdaWork
nvm use lts/carbon
npm install
```

## Step 7 - Create the IAM role and policies for Lambda

### Step 7a - Create the role

```
aws iam create-role --role-name Lambda-Fabric-Role --assume-role-policy-document file://Lambda-Fabric-Role-Trust-Policy.json > /tmp/lambdaFabricRole-output.json
```

This will output a JSON representation of the new role.  Copy the output to a local document so you can refer back to it later.

### Step 7b - Add policies to the role

We need to grant Lambda execution and Secrets Manager policies to the role.

```
aws iam attach-role-policy --role-name Lambda-Fabric-Role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole
aws iam put-role-policy --role-name Lambda-Fabric-Role --policy-name SecretsManagerPolicy --policy-document file://Secrets-Manager-Policy.json
```

## Step 8 - Create the Lambda function

### Step 8a - Create the Lambda archive

Archive the Lambda code into a zip file.

```
cd /tmp/lambdaWork
zip -r /tmp/health-function.zip  .
```

### Step 8b - Prepare and create the function

You now have everything you need to create the Lambda function, including the IAM role with the required policies, and the code archive. You will need to set a few input parameters to pass into the create-function call. We will do this by setting environment variables for the role ARN from the output of step 7a, and the SubnetID and SecurityGroupID, which are retrieved from our CloudFormation stack outputs.

You can set these environment variables by issuing these commands.

```
export ROLE_ARN=$(grep -o '"Arn": *"[^"]*"' /tmp/lambdaFabricRole-output.json | grep -o '"[^"]*"$' | tr -d '"')
export SUBNETID=$(aws cloudformation --region $REGION describe-stacks --stack-name $NETWORKNAME-fabric-client-node --query "Stacks[0].Outputs[?OutputKey=='PublicSubnetID'].OutputValue" --output text)
export SECURITYGROUPID=$(aws cloudformation --region $REGION describe-stacks --stack-name $NETWORKNAME-fabric-client-node --query "Stacks[0].Outputs[?OutputKey=='SecurityGroupID'].OutputValue" --output text)
```

Once you have set the environment variables, execute the create-function call below.

```
aws lambda create-function --function-name health-function --runtime nodejs8.10 --handler index.handler --memory-size 512 --role $ROLE_ARN --vpc-config SubnetIds=$SUBNETID,SecurityGroupIds=$SECURITYGROUPID --environment Variables="{CA_ENDPOINT=$CASERVICEENDPOINT,PEER_ENDPOINT=grpcs://$PEERSERVICEENDPOINT,ORDERER_ENDPOINT=grpcs://$ORDERINGSERVICEENDPOINT,CHANNEL_NAME=$CHANNEL,CHAIN_CODE_ID=ngo,CRYPTO_FOLDER=/tmp,MSP=$MSP,FABRICUSER=$FABRICUSER,MEMBERNAME=$MEMBERNAME}" --zip-file fileb:///tmp/health-function.zip --region $REGION --timeout 30
```

If you get an error indicating Function already exist: health-function, you can update the existing Lambda using the commands below. The first command updates the configuration of the Lambda function. The second command updates the code archive.

First, update the runtime configuration:

```
aws lambda update-function-configuration --function-name health-function --runtime nodejs8.10 --handler index.handler --memory-size 512 --role $ROLE_ARN --vpc-config SubnetIds=$SUBNETID,SecurityGroupIds=$SECURITYGROUPID --environment Variables="{CA_ENDPOINT=$CASERVICEENDPOINT,PEER_ENDPOINT=grpcs://$PEERSERVICEENDPOINT,ORDERER_ENDPOINT=grpcs://$ORDERINGSERVICEENDPOINT,CHANNEL_NAME=$CHANNEL,CHAIN_CODE_ID=ngo,CRYPTO_FOLDER=/tmp,MSP=$MSP,FABRICUSER=$FABRICUSER,MEMBERNAME=$MEMBERNAME}" --timeout 30 --region $REGION
```

Next, update the code archive:

```
aws lambda update-function-code --function-name health-function --zip-file fileb:///tmp/health-function.zip --region $REGION
```

## Step 9 - Create a VPC Endpoint to Secrets Manager

The Lambda function will run within a VPC, and therefore requires a VPC Endpoint to communicate with Secrets Manager.  We will do this with the `create-vpc-endpoint` command.

Before executing this command, we'll need to configure a few parameters.

From the AWS console, view the output of the [AWS Cloudformation](https://console.aws.amazon.com/cloudformation/home?region=us-east-1) stack you created in [Part 1](../ngo-fabric/README.md).

Click the 'Outputs' tab.
For `--vpc-id`, replace `string` with the value of `VPCID`.
For `--subnet-ids`, replace `string` with the value of `PublicSubnetID`.
For `--security-group-id`, replace `string` with the value of `SecurityGroupID`.

```
aws ec2 create-vpc-endpoint --vpc-id string --vpc-endpoint-type Interface --subnet-ids string --service-name com.amazonaws.us-east-1.secretsmanager --security-group-id string --region us-east-1
```

## Step 10 - Test the Lambda function

You can test the Lambda function from the [Lambda console](https://console.aws.amazon.com/lambda), or from the cli.

To test from the cli, we will first create a donor, and then query the donor.  The output of each command is in the file specified in the last argument:
```
aws lambda invoke --function-name health-function --payload '{"functionType": "invoke","chaincodeFunction": "createDonor","chaincodeFunctionArgs": {"donorUserName":"melissa","email":"melissa@melissasngo.org"}}' --region us-east-1 /tmp/lambda-output-invoke.txt
aws lambda invoke --function-name health-function --payload '{"functionType":"query","chaincodeFunction":"queryDonor","chaincodeFunctionArgs":{"donorUserName":"melissa"}}' --region us-east-1 /tmp/lambda-output-query.txt
```

## The workshop sections
The workshop instructions can be found in the README files in parts 1-4:

* [Part 1:](../ngo-fabric/README.md) Start the workshop by building the Hyperledger Fabric blockchain network using Amazon Managed Blockchain.
* [Part 2:](../ngo-chaincode/README.md) Deploy the non-profit chaincode. 
* [Part 3:](../ngo-rest-api/README.md) Run the RESTful API server. 
* [Part 4:](../ngo-ui/README.md) Run the application. 
* [Part 5:](../new-member/README.md) Add a new member to the network. 
* [Part 6:](../health/README.md) Read and write to the blockchain with AWS Lambda. 
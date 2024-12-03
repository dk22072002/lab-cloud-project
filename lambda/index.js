// index.js - Example Lambda function to process images
const AWS = require('aws-sdk');
const s3 = new AWS.S3();

exports.handler = async (event) => {
     
    console.log("Received event:", JSON.stringify(event, null, 2));
    
    const bucket = event.Records[0].s3.bucket.name;
    const key = event.Records[0].s3.object.key;

     
    const params = {
        Bucket: bucket,
        Key: key
    };
    
    try {
        const data = await s3.getObject(params).promise();
        console.log("File content retrieved:", data.Body.toString());
        
        return { statusCode: 200, body: 'Image processed successfully' };
    } catch (error) {
        console.error('Error processing file:', error);
        return { statusCode: 500, body: 'Error processing image' };
    }
};

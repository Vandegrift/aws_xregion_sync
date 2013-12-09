aws_xregion_sync
================

AWS Cross-Region Sync is a simple tool to help provide for easy disaster recovery by directly syncing AWS resources across AWS regions.

At this time only EC2 AMI and RDS Automated Snapshot syncing is supported.

## How To

Configuring and running AWS X Region Sync is done via a simple YAML configuration file.  The easiest way to show how to use the system is provide an example
config file and then walk through the options.

Assume the following config data is found in the file '/my/config.yaml':

```
{
  
  sync_my_web_app: {
    sync_type: "ec2_ami",
    source_region: "us-east-1",
    destination_region: "us-west-1",
    ami_owner: "12345678910123",
    sync_identifier: "Web Application",
    # http://docs.aws.amazon.com/AWSEC2/latest/CommandLineReference/ApiReference-cmd-DescribeImages.html
    filters: ["tag:Environment=Production", "tag-value=Sync"]
  },
  sync_my_database: {
    sync_type: "rds_automated_snapshot",
    source_region: "us-east-1",
    destination_region: "us-west-1",
    db_instance: "mydatabase",
    max_snapshots_to_retain: 5,
    aws_client_config: {
      aws_access_key: "my_other_access_key",
      aws_secret_key: "my_other_secret_key",
      aws_account_id: "4321-4321-4321"
    }
  },
  aws_client_config: {
    aws_access_key: "my_access_key",
    aws_secret_key: "my_secret_key",
  }
}
```

Each YAML key that starts with 'sync_' defines a distinct job to sync 1 particular resource.  Lets examine each of these sync types now.

### ec2_ami
The 'sync_my_web_app' job uses the 'ec2_ami' type which locates a single AMI instance associated with the given account credentials and will copy the image
and all resource tags associated with the image to the defined 'destination_region'.  If the source image has already been copied to the destination region 
this job will be a no-op.  The process utilizes a single resource tag as means of tracking if the image has already been synced and will NOT repeatedly sync 
the same image to the same region if it can determine the destination region already contains a copy of the source image.

Copying the image may take quite some time, depending on the size of the AMI.  The sync job does not block while the image is being copied and will not report
the final status of the AWS copy task.  It is assumed that the AMI copy will eventually complete.

#### ec2_ami Configuration

The following configuration options are available for 'ec2_ami' sync jobs (star'ed options are required):

- source_region * - The name of the AWS region the source EC2 AMI will be found in.
- destination_region * - The name of the AWS region the source EC2 AMI should be copied to.
- ami_owner - The AWS owner id of the AMI.  If left blank, the account associated with the AWS client credentials is used.
- sync_identifier - If given, a resource tag named 'Sync-Identifier' with the provided value will expected to be associated with the source AMI.  This is probably the simplest means of identifying which AMI to sync.
- filters - An array of String filter values that can be used to further filter AMI options down to a single source AMI.  Multiple filters are ANDed togther.  See the 'filter' parameter here for further explanation of available filter values: http://docs.aws.amazon.com/AWSEC2/latest/CommandLineReference/ApiReference-cmd-DescribeImages.html

In general, the combination of ami_owner, sync_identifier, and filter options MUST narrow down the list of AMI images to a SINGLE AMI.  If they do not, the sync job will be aborted.

NOTE: Under the covers, the sync task is performed by the AWS <a href="http://docs.aws.amazon.com/AWSEC2/latest/CommandLineReference/ApiReference-cmd-CopyImage.html">ec2-copy-image</a> API method.

### rds_automated_snapshot
The 'sync_my_database' job uses the 'rds_automated_snapshot' type which locates the newest automated rds snapshot associated with the given 'db_instance' and utilizes
the AWS copy_snapshot functionality to copy the snapshot to the destination region.  If the source snapshot is determined to already have been synced to the destination
snapshot the job will be a no-op.  The process utilizes the snapshot's created at attribute combined with a resource tag on destination snapshots to determine if
the snapshot has already been synced.

Copying the snapshot may take quite some time, depending on the size of the snapshot and amount of time since the last snapshot has been synced.  
The sync job does not block while the snapshot is being copied and will not report the final status of the AWS copy task. 
It is assumed that the snapshot copy will eventually complete.

NOTE: Under the covers, the sync task is performed by the AWS <a href="http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-CopyDBSnapshot.html">rds-copy-db-snapshot</a> API method.  Please see it for any further explanation of how the sync is performed.  In particular note that once an initial snapshot
has been copied only incremental changes are copied between regions, saving both time and bandwidth costs.  Each source automated snapshot that is
copied will result in a new destination snapshot.  The sync job will retain however many snapshots in the destination region you would like to keep.

#### rds_automated_snapshot Configuration

The following configuration options are available for 'ec2_ami' sync jobs (star'ed options are required):

- source_region * - The name of the AWS region the source RDS Snapshot will be found in.
- destination_region * - The name of the AWS region the source RDS Snapshot should be copied to.
- db_instance * - The RDS DB Instance Identifier value for the source database in the source region.
- max_snapshots_to_retain - The number of snapshots to retain in the destination region.  Defaults to retaining 2 existing ones - which ends up being 3 total including the one in the process of copying.  You'll probably wan't to keep this to at least 1 so that you'll always have at least a single previous snapshot available while the current one copies over to the dest. region.
- aws_client_config/aws_account_id- The AWS API for RDS snapshot tags requires providing an account number, therefore, the effective aws_client_credentials utilized for an rds snapshot sync can contain an account number.  This value can be found automatically in a rather hacky fashion by examining IAM user ARNs associated with the AWS keys, and this method will be utilized if no aws_account_id is provided.  However, be prepared for this method to fail and to have to provide the account id directly.

### aws_client_config

The 'aws_client_config' values can be defined both at a global level and/or inside each individual sync job.  The values defined at the global level are merged
together with any values defined at the job level (pretty much exactly as global_config.merge(job_config)).  The resulting config hash comprised of one or both values
are then passed directly to the AWS SDK.  Because of this, you can provide any acceptable configuration values to the AWS ruby SDK client.

Addtional aws client config properties are:

- aws_account_id - Some sync tasks require the use of a account id to construct ARN's.  In some cases, the account id can be deduced from the access and secret key via an IAM user lookup.  When this is not possible, an error will be raised associated with the sync job and you will need to provide the aws_account_id manually.

## Sample Code

In general, the only class/method your code needs to call is the AwsXRegionSync.run method.  It will return you a collection of AwsXRegionSync::SyncResult objects, 
one for each sync job contained in your config file.

Here's a really simple, direct example of running the config file above (apologies for verbosity of if statements - easiest most direct way of showing potential return values from the run method):
```ruby
require 'aws_xregion_sync'
results = AwsXRegionSync.run '/my/config.yaml'
results.each do |result|
  if result.failed?
    puts "#{result.name} encountered the following errors:\n#{result.errors.map(&:message).join('\n')}"
  else
    # If an image/snapshot was created by the job, created_resource will be populated. 
    # Resources may not be created in such cases where an EC2 image may already be in sync.
    if result.created_resource
      puts "#{result.name} successfully completed and created the AWS resource #{result.created_resource}."
    else
      puts "#{result.name} successfully completed without creating any new AWS resources."
    end
  end
end

```

## Contributing

Yes, this code is still very rough and not a whole lot of bells and whistles are currently supported.  See something you want added or have a bug that needs sqashing?  
Feel free to open an issue and we'll get back to you OR better yet, fork the project, create a topic branch, code up your awesome change, push to your branch and open a pull request with us.  

Because we're actually dog-fooding this project, if you make sweeping changes and/or functionality changes we can't absolutely guarantee we'll merge your pull request but we'll 
at least consider everything.  Create an issue if there's any doubt and we'll respond.

Please note, by submitting a pull request you are declaring that you have the right to submit the modifications contained in the request for inclusion into the aws_xregion_sync project 
and do also agree that your modifications may be licensed under the current license associated with this project at the time of the pull request.

License
-------

aws_xregion_sync is available under the LGPLv3 license, see the LICENSE.md, COPYING.txt and COPYING.LESSER.txt files for full details.
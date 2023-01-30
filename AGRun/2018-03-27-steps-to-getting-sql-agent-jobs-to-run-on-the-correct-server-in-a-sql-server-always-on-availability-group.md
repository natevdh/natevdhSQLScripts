---
layout: post
title: Steps to getting SQL Agent Jobs to run on the correct server in a SQL Server Always On Availability Group
date: 2018-03-27 21:34:00 -0500
categories: SQLServer
---

As stated in my previous post you need to sync different objects between servers when using an Always On Availability Group. One of those things was SQL Agent Jobs. Once the jobs are synced to all of the servers you need to take another step. That step is to ensure that jobs are running only once so that you don’t have multiple copies either all sucking down resources or even worse… overwriting each other.

I have had to write similar code multiple times at multiple clients and decided to take what I have learned from those (both successes and failures) and build a new version completely outside of current client work so that I can share it with all of you.

## Goals

- Only have jobs run on the primary server when it is in an Availability Group
- Have the ability to have a job run on a server that does not have an Availability Group setup
    - This is needed if one of your environments does not have an Availability Group (IE Dev/CI/Test etc) or if you are intentionally taking the databases out of the Availability Group.
    - Also important when keeping the jobs looking the same in every environment. In previous versions I had built people forgot to add the steps when it reached PD which caused unexpected errors.
- Easy to add or remove the job steps
- Easy way to verify that the job steps exist and have proper configuration

## What the process does

The overall idea is that every time a job runs you need to get to one of 3 states:

1. The Job runs normally
2. The Job does not run and complete with a success status
3. The Job does not run and ends in a failure status when there is a problem

In order to accomplish all 3 states we add 2 SQL Agent Job steps. The reason we add 2 is because SQL Agent Job Steps only have 2 states when exiting the step. Success or Failure.

For this example we have a simple 1 step SQL Agent Job

Original

```text
Step 1
- Run SSIS Package
```

After the stored procedure to add the AGRun Steps has been executed

```text
Step 1
- On Success go to Step 3
- On Failure go to Step 2
Step 2
- On Success report Success [2. The Job does not run and complete with a success status]
- On Failure report Failure [3. The Job does not run and ends in a failure status when there is a problem]
Step 3 (Former step 1)
- Run SSIS Package [1. The Job runs normally]
```

### Step 2

Step 2 does a number of different checks just to make sure everything is setup correctly.

1. Does the Configuration exist?
2. Does the Driver Database exist on this server?
    - Drive Database will be described more in setup section
3. Also does a check to ensure the SP exists (by failing if it doesn’t)
    - This can occur when you first copy the SQL Agent Job to a new server

### Step 1

Step 1 does Everything that Step 2 does plus 2 additional Steps.

1. It does a check to see if the driver database is in the availability group.
2. It decides if it should run.
    - If the driver database is the primary in the availability group OR if it is not in an AG and has the bit in the config set to 1 then it completes the step successfully which has the rest of the job run normally.
    - Else It will throw an error so that it goes into Step 2.

## Setup

### Installation

You can install these objects in any database that is not part of the availability group. I would recommend putting them in a database setup to just hold DBA objects instead of a system or separate application database.

New Objects – Scripts found on [github](https://github.com/natevdh/natevdhSQLScripts/tree/master/AGRun)

- SQLJob – Schema
- SQLJob.AGRunAddSteps – Stored Procedure
- SQLJob.AGRunDropSteps – Stored Procedure
- SQLJob.AGRunStatusCheck – Stored Procedure
- SQLJob.AGRunConfig – Table
- SQLJob.AGRunJobList – Table Type
- SQLJob.AGRunReviewer – View

You will need to populate the AGRunConfig table after you have created it.

AGRunConfig has 3 required columns:

- ConfigName
    - Name for the config – This will go in the Added Job Steps so that they know which configuration to use
- DriverDatabase
    - This is the database that you will be watching to see if it is in the availability group or not
- RunIfNotInAG
    - This is used to control if the job will run or not when it is not in an availability group

### Adding the Steps to Jobs

This Adds the AGRun Steps to the list of SQLAgentJobs provided.

- If the SQL Agent Jobs passed in as a parameter already has the AGRun steps, it will drop and re-add them.
- This is to allow you to change the Config name easily and allow for re-running of the scripts without error

IsDebug – (Optional Parameter)

- if NULL or 0 is passed the stored procedure will add steps
- if 1 is passed the stored procedure will show a before and after of the job steps and then roll back

Example:

```sql
DECLARE @SQLAgentJobs SQLJob.AGRunJobList

INSERT INTO @SQLAgentJobs (
   SQLAgentJobName
   , AGRunConfigName
)
VALUES
   ( 'AGDemo - Simple Job' , 'AGDemo' )

EXECUTE SQLJob.AGRunAddSteps
   @SQLAgentJobs = @SQLAgentJobs -- AGRunJobList
   , @IsDebug = 1 -- bit
```

### Removing the Steps from a Job

This removes the job steps if they exist and sets the start step to the appropriate step. It was built presuming that you would not want to do this in bulk so it only takes in 1 job name at a time.

Example:

```sql
EXEC SQLJob.AGRunDropSteps
   @SQLAgentJobName = 'AGDemo - Simple Job'
```

### Verification

The view SQLJob.AGRunReviewer is here to give you a general idea of if the AGRun steps have been added and if they have been configured correctly.

The AGRunStatus column has 3 types of statuses

1. No AGRun Steps Setup
2. AGRun Steps Configured
3. Error-(Error Description)

Does error checks for

1. If the AGRun steps have been bypassed
2. If the config is currently missing
3. If the Step1 and Step2 are not using the same config name

## Conclusion

Hopefully you will find these steps helpful in getting your Availability Group setup and running correctly.

If you find any bugs please add them as a github issue so that we can get them fixed for everyone.

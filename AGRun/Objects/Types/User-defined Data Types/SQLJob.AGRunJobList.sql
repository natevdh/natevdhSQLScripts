CREATE TYPE [SQLJob].[AGRunJobList] AS TABLE
(
[SQLAgentJobName] [sys].[sysname] NOT NULL,
[AGRunConfigName] [varchar] (100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
PRIMARY KEY CLUSTERED  ([SQLAgentJobName])
)
GO

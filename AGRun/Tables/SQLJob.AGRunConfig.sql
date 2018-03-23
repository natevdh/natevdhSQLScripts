CREATE TABLE [SQLJob].[AGRunConfig]
(
[AGRunConfigName] [varchar] (100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
[DriverDatabase] [sys].[sysname] NOT NULL,
[RunIfNotInAG] [bit] NOT NULL
) ON [PRIMARY]
GO
ALTER TABLE [SQLJob].[AGRunConfig] ADD CONSTRAINT [PKC_AGRunConfig_ConfigName] PRIMARY KEY CLUSTERED  ([AGRunConfigName]) ON [PRIMARY]
GO

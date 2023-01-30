---
layout:    post
title:    SQL Trigger to block permissions assigned directly to users
date:    2014-05-03 23:25:59 -0500
categories:    SQLServer
---
I recently spent a while at work cleaning up the permissions on a database. Some of the steps followed:

- All users are now assigned to a role
- Appropriate permissions were given to the roles
- All permissions (except for connect) were removed from the users

Now that I spent all of the time and energy getting the roles setup and getting the development team to agree to and **understand** how and why we wanted everyone assigned to a role, I wanted to ensure that no future permissions get given directly to users. To that end I wrote this trigger to revert any permissions that someone may try to give. It is still easy to turn off but I wanted to give whomever was assigning the rights another chance to reconsider if this is what they really wanted to do.

```sql
CREATE TRIGGER PermissionTrigger ON DATABASE
FOR GRANT_DATABASE AS
BEGIN
    --Does a check if the permissions are being assigned to a user (Both SQL and Windows)
    IF EXISTS (
        SELECT 1
        FROM (
            --List of Grantee's from the EventData
            SELECT Grantee.value('(text())[1]', 'nvarchar(128)') AS PrincipalName
            FROM (SELECT EVENTDATA() AS XMLData) x
            CROSS APPLY x.XMLData.nodes('//EVENT_INSTANCE/Grantees/Grantee') AS Grantees(Grantee)
        ) G
        JOIN sys.database_principals dp ON dp.NAME = g.PrincipalName
        WHERE dp.type IN ('S','U') --SQL Users and Windows Users
    )
    BEGIN
        RAISERROR ('You can not assign permissions to a user. If you think it is in error please contact a DBA',10,1)
        ROLLBACK
    END
END
```

Edit: 2017-03-20 script is now on [github](https://github.com/natevdh/natevdhSQLScripts/tree/master/PermissionTrigger)

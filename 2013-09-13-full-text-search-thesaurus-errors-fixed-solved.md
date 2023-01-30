---
layout: post
title: Full Text Search Thesaurus Errors - Fixed / Solved
date: 2013-09-13 13:38:45 -0500
categories: SQLServer
---

## Initial Symptoms

We got a ticket from a customer where searches were not working and when we executed the SP we got the following error

```text
Msg 30049, Level 17, State 10, Procedure <SP Name>, Line 126
Fulltext thesaurus internal error (HRESULT = '0x8007054e')
```

## Starting Steps

Looked at the SP and got which full text index it was trying to use.

We tried rebuilding the full text index. That didn't work.

We tried rebuilding the Full Text Catalogs... This actually caused SQL Server Management Studio (SSMS) to crash and restart.

We also tried to delete and completely re-add the Full Text Index.

We were able to figure out how to manually reload the Full Text Search Thesaurus for english by executing  `EXEC sys.sp_fulltext_load_thesaurus_file 1033,0;`
This worked fine in QA but failed where we were working on it. In Production, it gave us the error

```text
Msg 208, Level 16, State 1, Procedure sp_fulltext_load_thesaurus_file, Line 60
Invalid object name 'tempdb.sys.fulltext_thesaurus_metadata_table'.
Msg 266, Level 16, State 2, Procedure sp_fulltext_load_thesaurus_file, Line 60
Transaction count after EXECUTE indicates a mismatching number of BEGIN and COMMIT statements. Previous count = 0, current count = 1.
```

## Where the fun begins

This lead us to looking into tempdb. If you run the following query

```sql
SELECT name
FROM tempdb.sys.objects
WHERE type = 'IT'
AND name like ('FullText%')
```

You should see the following 3 tables:

- fulltext_thesaurus_metadata_table
- fulltext_thesaurus_phrase_table
- fulltext_thesaurus_state_table

None of these tables were there. These are internal tables to tempdb and cannot be created by a user. But normally tempdb is fully recreated when you restart the sql server service.
After a restart of the service...... the tables are still not there.

We obviously did other troubleshooting like `dbcc checkdb`'s on both the problem database and tempdb and they came back with no errors.

## What finally fixed the root problem

We are not sure what caused the tables to go missing in the first place but they should have come back after the restart of the sql server service. The problem after the restart was that one of the other databases (Database C) on the server was stuck in recovery mode and apparently the thread that adds the tables to the tempdb is the same thread or was blocked by the thread that was trying to bring Database C out of recovery.

1. To fix it we turned SQL Server back off.
2. Renamed the mdf for Database C. (This caused the Recovery to be skipped.)
3. Started SQL Server.
4. Hurray the tempdb tables were back.
5. Ran `EXEC sys.sp_fulltext_load_thesaurus_file 1033,0;` This should not be needed but wont hurt anything.
6. Renamed the file for Database C back to what it was.
7. Tried to access Database C from SSMS. (This caused it to look at the file again and put it back into recovery mode so it could finish.)

We were able to verify that Full Text Search was working again and were able to get Database C fixed.

Note: This was on SQL Server 2008 R2

--� 2019 | ByrdNest Consulting

-- ensure a USE <databasename> statement has been executed first. 
--USE <Database>    
GO
/****************************************************************************************

    Index Rebuild (defrag) script with logic from Jeff Moden and
        additional logic to change fillfactor as needed

    Designed to work with SS2012 and later, Enterprise Edition and 
        Developer Edition.  If you are using Standard Edition, you
        will need to modify the dynamic SQL and remove ONLINE = ON

    This script was created to rebuild clustered and non-clustered 
        indexes with average fragmentation > 1.2%.  It picks the top 
        15 (configurable) worse average fragmented indexes for an index 
        rebuild and it also varies each index fill factor (not heaps or 
        partitioned tables) to determine a "near optimum" value for 
        existing conditions.  Once a fill factor value is determined, it 
        is fixed for each succeeding execution of this script.  If the 
        fill factor value has not changed in last 90 days (configurable),
        it is again put in the queue for finding the best fill factor 
        (rationale for this logic is that data skew and calling patterns 
        from applications may change over time).

    If a table and its indexes are partitioned, this script rebuilds the 
        appropriate index partition with no adjustment to the fill factor.  

    This script should be executed from a SQL Agent job that runs daily 
        -- recommend time when server is least active.  It also depends on 
           a table (created by this script first time run) to store index 
           parametrics for the fill factor determination.

    You may alter this code for your own *non-commercial* purposes. You may
    republish altered code as long as you include this copyright and give 
     due credit. 


    THIS CODE AND INFORMATION ARE PROVIDED "AS IS" WITHOUT WARRANTY OF 
    ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED 
    TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A
    PARTICULAR PURPOSE. 

    Created         By                Comments
    20190424        Mike Byrd        Created
    20190513        Mike Byrd        Added additional data columns to 
                                         AgentIndexRebuilds table
    20190604        Mike Byrd        Added additional logic for setting FixFillFactor
    20190616        Mike Byrd        Revised FillFactor logic
    20190718        Mike Byrd        Added logic to get bad page splits (thanks to Jonathan Kehayias)
                                         https://www.sqlskills.com/blogs/jonathan/tracking-problematic-pages-splits-in-sql-server-2012-extended-events-no-really-this-time/

****************************************************************************************/



--Set Configuration parameters
DECLARE @RedoPeriod          INT     = 90    --Days
DECLARE @TopWorkCount        INT     = 15    --Specify how large result 
                                             --     set for Work_to_Do
--  --get current database name
DECLARE @Database            SYSNAME = (SELECT DB_NAME())  



/********************************************************************
code setup for Always On Primary Node; comment out next 4 statements
      if not an Always On Node
**********************************************************************/
--  DECLARE @preferredReplica INT
--  SET @preferredReplica 
--    = (SELECT [master].sys.fn_hadr_backup_is_preferred_replica(@Database))
--  IF (@preferredReplica = 0)
BEGIN
    DECLARE @Date                                DATETIME = GETDATE()    
    DECLARE @RowCount                            INT = 0    
    DECLARE @objectid                            INT     
    DECLARE @indexid                             INT     
    DECLARE @partitioncount                      BIGINT     
    DECLARE @schemaname                          SYSNAME     
    DECLARE @objectname                          SYSNAME     
    DECLARE @indexname                           SYSNAME     
    DECLARE @partitionnum                        BIGINT     
    DECLARE @partitions                          BIGINT     
    DECLARE @frag                                FLOAT     
    DECLARE @FillFactor                          INT    
    DECLARE @OldFillFactor                       INT    
    DECLARE @FixFillFactor                       INT    
    DECLARE @LagDate                             INT    
    DECLARE @NewFrag                             FLOAT    
    DECLARE @NewPageSplitForIndex                BIGINT    
    DECLARE @NewPageAllocationCausedByPageSplit  BIGINT    
    DECLARE @PageCount                           BIGINT    
    DECLARE @RecordCount                         BIGINT    
    DECLARE @ForwardRecordCount                  BIGINT    
    DECLARE @NewForwardRecordCount               BIGINT    
    DECLARE @Command                             NVARCHAR(4000)    
    DECLARE @Msg                                 VARCHAR(256)    
    DECLARE @PartitionFlag                       BIT = 0    
    SET NOCOUNT ON     
    SET QUOTED_IDENTIFIER ON;                --needed for XML ops in query below
 
 
 
    -- ensure the temporary work table does not exist 
    IF OBJECT_ID(N'tempdb..#work_to_do') IS NOT NULL DROP TABLE #work_to_do     

    -- get worse avg_fragmentation indexs (TOP @TopWorkCount)
    -- conditionally select from the function, 
    SELECT  TOP (@TopWorkCount) *         
        INTO #work_to_do     
        FROM ( SELECT         
           ps.object_id objectid, 
           ps.index_id  indexid, 
           o.[name]     TableName,
           i.[name]     IndexName,
           ps.partition_number partitionnum, 
           ps.avg_fragmentation_in_percent frag,
           ios.LEAF_ALLOCATION_COUNT PAGE_SPLIT_FOR_INDEX,
           tab.split_count BadPageSplit,
           ios.NONLEAF_ALLOCATION_COUNT PAGE_ALLOCATION_CAUSED_BY_PAGESPLIT,
           CASE WHEN i.Fill_Factor = 0 THEN 100 
                ELSE i.Fill_Factor END Fill_Factor,
           ps.page_count,
           ps.record_count,
           ps.forwarded_record_count,
           ps.avg_page_space_used_in_percent,
           NULL New_Frag,
           NULL New_PageSplitForInde,
           NULL New_PageAllocationCausedByPageSplit,
           NULL New_forwarded_record_count,
           0 [Redo_Flag],
           ROW_NUMBER() OVER (PARTITION BY ps.object_id,ps.index_id,ps.partition_number,tab.split_count ORDER BY tab.split_count DESC)   [RowNumber]
        --  --get data for all tables/indexes
        --  SAMPLED gives same avg fragmentation as DETAILED and is much faster
        FROM sys.dm_db_index_physical_stats (DB_ID(@Database),NULL,NULL,NULL,'SAMPLED') ps 
        JOIN sys.dm_db_index_operational_stats(DB_ID(@Database),NULL,NULL,NULL) ios
          ON  ios.index_id         = ps.index_id
          AND ios.[object_id]      = ps.[object_id]
          AND ios.partition_number = ps.partition_number
          AND ps.index_level       = 0
        JOIN sys.indexes i
          ON  i.index_id           = ps.index_id
          AND i.[object_id]        = ps.[object_id]
        JOIN sys.objects o
          ON o.[object_id]         = i.[object_id]
        JOIN sys.partitions p
          ON  p.[object_id]           = i.[object_id]
          AND p.index_id           = i.index_id
        LEFT JOIN sys.allocation_units au
          ON au.container_id       = p.[partition_id]
        LEFT JOIN (SELECT 
                    n.value('(value)[1]', 'bigint') AS alloc_unit_id,
                    n.value('(@count)[1]', 'bigint') AS split_count
                FROM (SELECT CAST(target_data as XML) target_data
                         FROM sys.dm_xe_sessions AS s 
                         JOIN sys.dm_xe_session_targets t
                           ON s.address = t.event_session_address
                         WHERE s.name = 'SQLskills_TrackPageSplits'
                          AND t.target_name = 'histogram' ) as tab
                CROSS APPLY target_data.nodes('HistogramTarget/Slot') as q(n) ) AS tab
          ON tab.alloc_unit_id = au.allocation_unit_id
        WHERE i.index_id           > 0
          AND o.[type]             = 'U'
          AND ps.avg_fragmentation_in_percent > 1.20   --this is rebuild condition
          AND ps.index_level       = 0 ) sub
    /*******************************************************************  
        The ORDER BY below looks at max avg_frag and then alternates the 
        next day with indexes with max page splits.  
    *********************************************************************/
    WHERE sub.RowNumber = 1
    ORDER BY CASE WHEN DAY(getdate()) % 2 = 1 
                      THEN sub.frag
                  ELSE sub.BadPageSplit/sub.page_count END DESC   
--SELECT * FROM #work_to_do

/**********************************************************************
     Reset TrackPageSplits Extended Event
***********************************************************************/
    SET @command = N'
            -- Stop the Event Session to clear the target
            ALTER EVENT SESSION [SQLskills_TrackPageSplits]
            ON SERVER
            STATE=STOP'

    EXEC sys.sp_executesql @command     

SET @command = N'
            -- Start the Event Session Again
            ALTER EVENT SESSION [SQLskills_TrackPageSplits]
            ON SERVER
            STATE=START'

    EXEC sys.sp_executesql @command   
    

/************************************************************************
    Go back and find oldest index (>@RedoPeriod) with @FixFillFactor 
        and add it to #work_to_do 
        (to keep index fill factors from getting "stale").
***********************************************************************/
    IF OBJECT_ID(N'tempdb..#Temp2') IS NOT NULL DROP TABLE #Temp2    
    SELECT  TOP(1) CREATEDATE,ID,DBName,SchemaName,TableName,IndexName
            ,PartitionNum,Current_Fragmentation,New_Fragmentation
            ,PageSplitForIndex,New_PageSplitForIndex
            ,PageAllocationCausedByPageSplit
            ,New_PageAllocationCausedByPageSplit
            ,[FillFactor],[Object_ID],Index_ID,page_count
            ,record_count,forwarded_record_count
            ,New_forwarded_record_count,LagDays,FixFillFactor
        INTO #Temp2
        FROM [Admin].AgentIndexRebuilds r
        WHERE r.CREATEDATE <= DATEADD(dd,-@RedoPeriod,GETDATE())    
          AND r.DBName = @Database
          AND r.FixFillFactor IS NOT NULL
          AND r.DelFlag <> 1
          AND NOT EXISTS (SELECT 1  FROM [Admin].AgentIndexRebuilds r2
                                    WHERE r2.DBName          = @Database
                                      AND r2.[Object_ID]     = r.[Object_ID]
                                      AND r2.Index_ID        = r.Index_ID
                                      AND r2.PartitionNum    = r.PartitionNum
                                      AND r2.ID              > r.ID)
          --don't get partitioned tables (no adjusting fill factor)
          AND NOT EXISTS (SELECT 1 FROM sys.partitions p 
                                   WHERE p.object_id = r.object_id
                                     AND p.index_id  = r.index_id
                                     AND p.partition_number > 1)
        ORDER BY ID DESC, CreateDate DESC
        SET @RowCount = @@ROWCOUNT    
--SELECT * FROM #Temp2

/**********************************************************************
    Go back and recalculate FillFactor for oldest Table/Index 
        in Admin.AgentIndexRebuilds
***********************************************************************/
    IF @RowCount = 1            
        BEGIN
            UPDATE #Temp2
                -- start pertubation cycle over again    
                SET [FillFactor] = CASE WHEN Index_ID > 1 
                                         AND FixFillFactor > 90 
                                            THEN 98
                                        WHEN Index_ID > 1 
                                         AND FixFillFactor > 80 
                                            THEN 94
                                        WHEN Index_ID > 1 
                                         AND FixFillFactor >=70 
                                            THEN 90
                                        ELSE 100 END, --reset CI back to 100
                        FixFillFactor = NULL          --reset FixFillFactor so that 
                                                      --  regression can begin

/**********************************************************************
    Reset fixfillfactor from previous passes (need to reset it for 
    all rows with Object_ID, Index_ID, & PartitionNum
***********************************************************************/
            UPDATE r
                SET FixFillFactor = NULL
                FROM [Admin].AgentIndexRebuilds r
                JOIN #Temp2 t
                  ON  t.[Object_ID]  = r.[Object_ID]
                  AND t.Index_ID     = r.Index_ID
                  AND t.PartitionNum = r.PartitionNum
                  AND (r.DelFlag     IS NULL OR r.DelFlag = 0)
                WHERE r.DBName      = @Database;   

            --add new row to start regression
            INSERT INTO #work_to_do
                       (objectid,indexid,TableName,IndexName,partitionnum
                       ,frag,PAGE_SPLIT_FOR_INDEX
                       ,PAGE_ALLOCATION_CAUSED_BY_PAGESPLIT,Fill_Factor
                       ,page_count,record_count,forwarded_record_count
                       ,avg_page_space_used_in_percent,New_Frag
                       ,New_PageSplitForIndex
                       ,New_PageAllocationCausedByPageSplit
                       ,New_forwarded_record_count,Redo_Flag)
                SELECT [OBJECT_ID], Index_ID, TableName,IndexName
                        ,PartitionNum,Current_Fragmentation
                        ,PageSplitForIndex,PageAllocationCausedByPageSplit
                        ,[FillFactor],page_count,record_count
                        ,forwarded_record_count,NULL,NULL
                        ,NULL,NULL,NULL,@RowCount [Redo_Flag]
                    FROM #Temp2    
        END


    -- Declare the cursor for the list of partitions to be processed. 
    IF EXISTS (SELECT 1 FROM #work_to_do) 
      BEGIN
        DECLARE [workcursor] CURSOR FOR 
            SELECT  DISTINCT w.objectid, w.indexid
                    , w.partitionnum, w.frag,w.Fill_Factor
                    ,w.TableName, w.IndexName
                    ,DATEDIFF(dd,sub.CreateDate,GETDATE()) LagDate
                    ,Redo_Flag
                FROM #work_to_do w
                JOIN sys.indexes i
                  ON  i.object_id = w.objectid
                  AND i.index_id  = w.indexid
                LEFT JOIN (SELECT TableName, IndexName, PartitionNum
                                 , MAX(CreateDate) CreateDate 
                             FROM [Admin].AgentIndexRebuilds r 
                             WHERE r.DBName = @Database
                             GROUP BY TableName,IndexName,PartitionNum) sub
                  ON  sub.TableName    = OBJECT_NAME(w.ObjectID)
                  AND sub.IndexName    = i.[name] 
                  AND sub.PartitionNum = w.partitionnum
                ORDER BY w.Frag DESC    

            -- Open the cursor. 
        OPEN [workcursor]     

        -- Loop through the [workcursor]. 
        FETCH NEXT FROM [workcursor] 
            INTO @objectid, @indexid, @partitionnum, @frag, @FillFactor
                ,@objectname,@indexname,@LagDate,@RowCount     

        WHILE @@FETCH_STATUS = 0 
          BEGIN 
            IF OBJECT_ID(N'tempdb..#Temp3') IS NOT NULL DROP TABLE #Temp3    

            SELECT @schemaname = s.[name] 
                FROM sys.objects AS o 
                JOIN sys.schemas as s 
                  ON s.schema_id  = o.schema_id 
                WHERE o.object_id = @objectid     

/**********************************************************************
    Cannot reset fillfactor if table is partitioned, but can rebuild 
        the specified partition number
***********************************************************************/
            IF @partitionnum > 1 OR 
                 EXISTS (SELECT 1 FROM sys.partitions p 
                                  WHERE p.object_id = @objectid
                                    AND p.Index_ID  = @indexid
                                    AND p.partition_number > 1)
                SET @PartitionFlag = 1
            ELSE
                SET @PartitionFlag = 0    

            SET @OldFillFactor = @FillFactor    

            SET @FixFillFactor = 
                (SELECT FixFillFactor 
                   FROM [Admin].[AgentIndexRebuilds] air1
                   WHERE air1.DBName = @Database
                     AND air1.ID =  (SELECT MAX(ID)    
                                       FROM [Admin].[AgentIndexRebuilds] air2
                                       WHERE air2.DBName       = @Database 
                                         AND air2.[Object_ID]  = @objectid
                                         AND air2.Index_ID     = @indexid
                                         AND air2.PartitionNum = @partitionnum))    


/**********************************************************************
     This is the logic for changing fill factor per index

     Clustered Indexes are perturbed by decrementing the current fill 
     factor by 1 and nonclustered indexes fill factors are decremented 
     by one or two depending on the length of time since the index was 
     last rebuilt.  Code is there to ensure the perturbed fill factor 
     is never less than 70%.  This is an arbitrary number I set and 
     can be changed if required.
***********************************************************************/
            IF @FixFillFactor IS NULL
              BEGIN
                SET @FillFactor = CASE  WHEN @RowCount = 1 
                                            THEN @FillFactor  --to catch redo index
                                        --clustered index, only decrement by 1
                                        --if already 100 then ratchet down
                                        WHEN @indexid = 1 and 
                                             @LagDate IS NULL 
                                          AND @FillFactor = 100 
                                            THEN 99    
                                        WHEN @indexid = 1 AND 
                                             @LagDate IS NULL 
                                             THEN 100
                                        WHEN @indexid = 1 AND 
                                             @LagDate <30 
                                             THEN @FillFactor -1
                                        --nonclustered indexes, 
                                        --  decrement fill factor 
                                        --  depending on Lag days.
                                        ----if already 100 then ratchet down
                                        WHEN @indexid > 1 AND 
                                             @LagDate IS NULL AND 
                                             @FillFactor = 100 
                                            THEN 98    
                                        WHEN @indexid > 1 AND 
                                             @LagDate IS NULL 
                                            THEN 100
                                        WHEN @indexid > 1 AND 
                                             @LagDate <  14 
                                            THEN @FillFactor -2
                                        WHEN @indexid > 1 AND 
                                             @LagDate >= 14 
                                            THEN @FillFactor -1
                                        ELSE @FillFactor END    

                        -- never let FillFactor get to less than 70
                IF @FillFactor < 70 
                  BEGIN    
                    SET @FillFactor = 70    
                    PRINT 'FillFactor adjusted back to 70.'    
                    UPDATE [Admin].AgentIndexRebuilds
                        SET FixFillFactor = @FillFactor
                        WHERE DBName    = @Database
                          AND Object_ID = @objectid
                          AND Index_ID  = @indexid
                          AND PartitionNum = @partitionnum
                  END
                END
            ELSE
                SET @FillFactor = @FixFillFactor    
--SELECT @FixFillFactor [@FixFillFactor],@PartitionFlag [@PartitionFlag]

			/**********************************************************
                Index is not partitioned
            ***********************************************************/
            IF @PartitionFlag = 0
              BEGIN
                SET @command = N'SET QUOTED_IDENTIFIER ON     
                    ALTER INDEX ' + QUOTENAME(@indexname) +' ON [' + @schemaname + 
                    N'].[' + @objectname + N'] REBUILD WITH (ONLINE = ON,'+
                    ' DATA_COMPRESSION = ROW,MAXDOP = 1,FILLFACTOR = '+
                    CONVERT(NVARCHAR(5),@FillFactor) + ')'     
              END

            /**********************************************************
            IF Index is partitioned, rebuild, but don't play with fill factor
            ***********************************************************/    
            IF @PartitionFlag = 1      
               BEGIN
                 SET @FillFactor = @OldFillFactor    
                 SET @command = N'SET QUOTED_IDENTIFIER ON     
                     ALTER INDEX ' + QUOTENAME(@indexname) +' ON [' + @schemaname 
                     + N'].[' + @objectname + N'] REBUILD PARTITION = ' 
                     + CONVERT(VARCHAR(25),@PartitionNum) + 
                     N' WITH (ONLINE = ON, DATA_COMPRESSION = ROW,MAXDOP = 1)'     
               END

            EXEC sys.sp_executesql @command     
            PRINT N'Executed ' + @command     

            /**********************************************************                
                Get new fragmentation after rebuild    
            ***********************************************************/
            SELECT ps.avg_fragmentation_in_percent
              INTO #Temp3
              FROM #work_to_do w
              JOIN sys.dm_db_index_physical_stats (DB_ID(@Database),@objectid
                                                   , @indexid,@partitionnum
                                                   ,'SAMPLED') ps
                ON  ps.index_id         = w.indexid
                AND ps.object_id        = w.objectid
                AND ps.partition_number = w.partitionnum
                AND ps.index_level      = 0
              WHERE w.indexid           = @indexid
                AND w.objectid          = @objectid
                AND w.partitionnum      = @partitionnum
                AND ps.index_level      = 0    
--SELECT * FROM #Temp3

/********************************************************************** 
    If new frag > old frag, go back 1% fill factor, rebuild index, 
        and set FixFillFactor (for non-partioned indexes only)
***********************************************************************/
            IF EXISTS (SELECT 1 FROM #Temp3 
                                WHERE avg_fragmentation_in_percent > @frag 
                                  AND @OldFillFactor <> @FillFactor
                                  AND @RowCount = 0)
               AND @PartitionFlag = 0
                 BEGIN
                   PRINT 'Setting @FixFillFactor'
                   SET @FillFactor = @FillFactor + 1    
                   IF @FillFactor > 100 SET @FillFactor = 100    
                   SET @FixFillFactor = @FillFactor    
                   --archive out old data for that table/index/partionnum
                   UPDATE r
                       SET DelFlag = 1
                       FROM [Admin].AgentIndexRebuilds r
                       JOIN #Temp2 t2
                         ON  t2.DBName       = r.DBName
                         AND t2.Object_ID    = r.Object_ID
                         AND t2.Index_ID     = r.Index_ID
                         AND t2.PartitionNum = r.PartitionNum
                       WHERE r.DBName = @Database
                         AND r.Object_ID     = @objectid
                         AND r.Index_ID      = @indexid
                         AND r.PartitionNum  =  @partitionnum
                         AND r.ID            <= t2.ID
                         AND r.DelFlag      <> 1


                   SET @command = N'SET QUOTED_IDENTIFIER ON     
                       ALTER INDEX ' + @indexname + N' ON [' + @schemaname 
                       + '].[' + QUOTENAME(@objectname) + N'] REBUILD ' 
                       + N'WITH (ONLINE=ON,DATA_COMPRESSION=ROW,MAXDOP=1,' + 
                       N'FILLFACTOR = '+CONVERT(NVARCHAR(5),@FillFactor) +
                       ')'     

                   EXEC  sys.sp_executesql @command     
                   PRINT N'Executed ' + @command     

                 END    

                --insert results into history table (AgentIndexRebuilds)
            INSERT [Admin].AgentIndexRebuilds (CREATEDATE, DBName
                    , SchemaName, TableName, IndexName, PartitionNum
                    , Current_Fragmentation, New_fragmentation
                    , PageSplitForIndex, BadPageSplits, New_PageSplitForIndex
                    , PageAllocationCausedByPageSplit
                    , New_PageAllocationCausedByPageSplit, [FillFactor]
                    , [Object_ID], Index_ID
                    , page_count, record_count, forwarded_record_count
                    , New_forwarded_record_count, LagDays,FixFillFactor,DelFlag)
                    SELECT @DATE,@Database,@schemaname,@objectname
                          ,@indexname,@partitionnum,@frag
                          , ps.avg_fragmentation_in_percent
                          ,w.PAGE_SPLIT_FOR_INDEX,w.BadPageSplit,ios.LEAF_ALLOCATION_COUNT
                          ,w.PAGE_ALLOCATION_CAUSED_BY_PAGESPLIT
                        ,ios.NONLEAF_ALLOCATION_COUNT,@FillFactor,w.objectid
                        ,w.indexid,w.page_count,w.record_count
                        ,w.forwarded_record_count,ps.forwarded_record_count
                        ,@LagDate,@FixFillFactor,1
                        FROM #work_to_do w
                        JOIN sys.dm_db_index_physical_stats 
                             (DB_ID(@Database),@objectid,@indexid,@partitionnum
                             ,'SAMPLED') ps
                          ON  ps.index_id         = w.indexid
                          AND ps.object_id        = w.objectid
                          AND ps.partition_number = w.partitionnum
                          AND ps.index_level      = 0
                        JOIN sys.dm_db_index_operational_stats
                             (DB_ID(@Database),@objectid,@indexid,@partitionnum) ios
                          ON  ios.index_id         = ps.index_id
                          AND ios.object_id        = ps.object_id
                          AND ios.partition_number = ps.partition_number
                        WHERE w.indexid            = @indexid
                          AND w.objectid           = @objectid
                          AND w.partitionnum       = @partitionnum
                          AND ps.index_level = 0    

             SET @PartitionFlag = 0    
             FETCH NEXT 
                 FROM [workcursor] 
                 INTO @objectid, @indexid, @partitionnum, @frag
                ,@FillFactor,@objectname,@indexname,@LagDate,@RowCount     
           END     
          -- Close and deallocate the cursor. 
            CLOSE [workcursor]     
            DEALLOCATE [workcursor]     
        

            --clean up
            IF OBJECT_ID(N'tempdb..#Temp2') IS NOT NULL 
                DROP TABLE #Temp2    
            IF OBJECT_ID(N'tempdb..#Temp3') IS NOT NULL 
                DROP TABLE #Temp3    
            IF OBJECT_ID(N'tempdb..#TablesWithLOBs') IS NOT NULL 
                DROP TABLE #TablesWithLOBs    
          END    
    IF OBJECT_ID(N'tempdb..#work_to_do') IS NOT NULL DROP TABLE #work_to_do     
    --Data retention
    DELETE [Admin].AgentIndexRebuilds
        WHERE CreateDate < DATEADD(yy,-3,GETDATE())
END    
GO

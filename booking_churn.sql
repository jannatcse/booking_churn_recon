-- final_merge_data@202501300206PM
with bookings as
         (
             ----BOOKING@202501300031
             WITH booking_filtered AS (SELECT *
                                       FROM jannat.bookings_dec24
                                       WHERE "Month # - Close Date" IN (10, 11, 12))
                , agg_booking AS (SELECT "Master Customer ID",
                                         SUM("recurring_revenue"::float) AS total_recurring_amount,
                                         sum(BTRIM(replace(RIGHT("Recurring Software Amount Change",
                                                                 length("Recurring Software Amount Change") - 3), ',',
                                                           ''))::float)     bookings_local_currency,
                                         array_agg("Opportunity ID")     as opportunity_id
                                  FROM booking_filtered bf
                                  GROUP BY 1)
                , sst_filtered AS (SELECT master_customer_id,
                                          sum(arr_usd_ccfx::float)                as arr_usd_ccfx,
                                          sum(baseline_arr_local_currency::float) as " ARR LCU TTL Customer Movement "
                                   FROM jannat.sst_to_adaptive_export_03012025_1520
                                   WHERE Type = 'Account Name Customer Bridge'
                                     AND snapshot_date BETWEEN '2024-10-31' AND '2024-12-31'
                                   group by 1
--            ,3
             )
                , uniue_bookings_date_mcid_data AS (SELECT distinct "Master Customer ID",
                                                                    "Celigo[AT]_Start Date",
                                                                    "Opportunity ID"
                                                    FROM booking_filtered)
                , latest_celigo AS (SELECT "Master Customer ID",
                                           array_agg("Opportunity ID")  AS opportunity_id,
                                           MAX("Celigo[AT]_Start Date") AS latest_celigo_start_date
                                    FROM uniue_bookings_date_mcid_data
                                    group by 1)
                , merged_data AS (SELECT c.epi_universal_id                     AS mcid,
                                         b.opportunity_id,
                                         c.*,
                                         b.total_recurring_amount               AS booking_amount_usd,
                                         a.arr_usd_ccfx,
                                         a." ARR LCU TTL Customer Movement ",
                                         COALESCE(b.total_recurring_amount, 0)  AS booking_amount_usd_filled,
                                         COALESCE(a.arr_usd_ccfx, 0)            AS arr_usd_ccfx_filled,
                                         COALESCE(b.bookings_local_currency, 0) AS bookings_local_currency,
                                         latest_celigo.latest_celigo_start_date as celigo_start_date
                                  FROM jannat.customer_detail_20250105 c
                                           LEFT JOIN agg_booking b
                                                     ON c.epi_universal_id = b."Master Customer ID"
                                           LEFT JOIN sst_filtered a
                                                     ON c.epi_universal_id = a.master_customer_id
                                           LEFT JOIN latest_celigo
                                                     ON latest_celigo."Master Customer ID" = c.epi_universal_id)
                , merged_with_flags AS (SELECT *,
                                               CASE
                                                   WHEN booking_amount_usd IS NULL AND arr_usd_ccfx IS NOT NULL
--                                           THEN 'ARR not in booking'
                                                       THEN 'Need to label'
                                                   WHEN booking_amount_usd IS NOT NULL AND arr_usd_ccfx IS NULL
--                                           THEN 'Booking not in ARR'
                                                       THEN 'Need to label'
                                                   ELSE 'both present'
                                                   END                                              AS missing_flag,
                                               arr_usd_ccfx_filled - booking_amount_usd_filled      AS diff,
                                               ABS(arr_usd_ccfx_filled - booking_amount_usd_filled) AS abs_diff
                                        FROM merged_data
                                        where coalesce(arr_usd_ccfx_filled, 0) > 0
                                           or coalesce(booking_amount_usd_filled, 0) > 0)
                , bookings_final AS (SELECT *,
                                            CASE
                                                WHEN booking_amount_usd_filled > 0
                                                    AND arr_usd_ccfx_filled > 0
                                                    AND abs_diff < 1000 THEN 'Immaterial'
                                                ELSE
                                                    CASE
                                                        WHEN celigo_start_date >= '2024-12-26' --bnsl_date
                                                            AND (arr_usd_ccfx = 0 or arr_usd_ccfx is null)
                                                            THEN 'Booked now, starts later'
                                                        ELSE 'N' END
                                                END AS label
                                     FROM merged_with_flags)
                , historical_booking_filtered_current_quarter AS (SELECT *
                                                                  FROM jannat.dec_2024
                                                                  WHERE "Month # - Close Date" IN (10, 11, 12))
                -------===========CURRENT MONTH START===========-------==============
                , agg_historical_booking_current_quarter AS (SELECT "Master Customer ID",
                                                                    SUM(hb.recurring_revenue::float) AS "current_quarter_revenue"
                                                             FROM historical_booking_filtered_current_quarter hb
                                                             GROUP BY "Master Customer ID")
                , current_quarter_bookings AS (select bf.*,
                                                      coalesce(ahb.current_quarter_revenue, 0) AS current_quarter_revenue
                                               from bookings_final bf
                                                        LEFT JOIN
                                                    agg_historical_booking_current_quarter ahb
                                                    on bf.mcid = ahb."Master Customer ID")
                -------===========CURRENT MONTH END===========-------===============
                , historical_booking_filtered_current_prev1_quarter AS (SELECT *
                                                                        FROM jannat.quartar_3_2024
                                                                        WHERE "Month # - Close Date" IN (7, 8, 9))
                , agg_historical_booking_prev1_quarter AS (SELECT "Master Customer ID",
                                                                  SUM(hb.recurring_revenue::float) AS prev1_quarter_revenue
                                                           FROM historical_booking_filtered_current_prev1_quarter hb
                                                           GROUP BY "Master Customer ID")
                , prev1_quarter_bookings AS (select
--         ahb."Master Customer ID",
bf.*,
coalesce(ahb.prev1_quarter_revenue::float, 0) AS prev1_quarter_revenue
                                             from current_quarter_bookings bf
                                                      LEFT JOIN
                                                  agg_historical_booking_prev1_quarter ahb
                                                  on bf.mcid = ahb."Master Customer ID")
                , historical_booking_filtered_current_prev2_quarter AS (SELECT *
                                                                        FROM jannat.quartar_2_2024
                                                                        WHERE "Month # - Close Date" IN (4, 5, 6))
                , agg_historical_booking_prev2_quarter AS (SELECT "Master Customer ID",
                                                                  SUM(hb.recurring_revenue::float) AS prev2_quarter_revenue
                                                           FROM historical_booking_filtered_current_prev2_quarter hb
                                                           GROUP BY "Master Customer ID")
                , prev2_quarter_bookings AS (select bf.*,
                                                    coalesce(ahb.prev2_quarter_revenue::float, 0) AS prev2_quarter_revenue
                                             from prev1_quarter_bookings bf
                                                      LEFT JOIN
                                                  agg_historical_booking_prev2_quarter ahb
                                                  on bf.mcid = ahb."Master Customer ID")
                , historical_bookings_final AS (select b1.*,
                                                       ABS(b1.arr_usd_ccfx - b1.prev1_quarter_revenue) AS absolute_booking_prev1_diff,
                                                       ABS(b1.arr_usd_ccfx - b1.prev2_quarter_revenue) AS absolute_booking_prev2_diff
                                                from prev2_quarter_bookings b1)
                , historical_labeling AS (select hb.mcid,
                                                 opportunity_id,
                                                 hb.epi_universal_id,
                                                 hb.name,
                                                 hb.booking_amount_usd,
                                                 hb.arr_usd_ccfx,
                                                 hb." ARR LCU TTL Customer Movement ",
                                                 hb.booking_amount_usd_filled,
                                                 hb.arr_usd_ccfx_filled,
                                                 hb.celigo_start_date,
                                                 hb.missing_flag,
                                                 hb.diff,
                                                 hb.abs_diff,
--                                     hb.booking_match,
                                                 hb.bookings_local_currency,
                                                 hb.current_quarter_revenue,
                                                 hb.prev1_quarter_revenue,
                                                 hb.prev2_quarter_revenue,
                                                 hb.absolute_booking_prev1_diff,
                                                 hb.absolute_booking_prev2_diff,
                                                 case
                                                     when hb.label = 'N' AND
                                                          (hb.booking_amount_usd = 0 or hb.booking_amount_usd is null)
                                                         AND hb.arr_usd_ccfx > 0 AND hb.prev1_quarter_revenue > 0 AND
                                                          hb.absolute_booking_prev1_diff <= 1000
                                                         THEN 'Booked previously, starts now    '
                                                     when hb.label = 'N' AND
                                                          (hb.booking_amount_usd = 0 or hb.booking_amount_usd is null)
                                                         AND hb.arr_usd_ccfx > 0 AND hb.prev2_quarter_revenue > 0 AND
                                                          hb.absolute_booking_prev2_diff <= 1000
                                                         THEN 'Booked previously, starts now    '
                                                     ELSE hb.label
                                                     END AS label
                                          from historical_bookings_final hb)
                , migration_ramp_price_uplift_winback AS (select saex.*,
                                                                 case
                                                                     when saex.bridge_account in
                                                                          ('Cross-sell - migration',
                                                                           'Up Sell - migration')
                                                                         THEN 'Upsell_Cross-sell_Migration'
                                                                     --                                                                     WHEN saex.bridge_account in
--                                                                          ('Downgrade - migration',
--                                                                           'Downsell - migration')
--                                                                         THEN 'Downsell_Downgrade_Migration'
                                                                     WHEN saex.bridge_account in
                                                                          ('Win back Downgrade', 'Win back Downsell',
                                                                           'Winback',
                                                                           'Lapsed Renewal')
                                                                         THEN 'Winback'
                                                                     WHEN saex.bridge_account = 'Price Ramp'
                                                                         THEN 'Price Ramp'
                                                                     WHEN saex.bridge_account = 'Price Uplift'
                                                                         THEN 'Price Uplift'
                                                                     END AS bridge
                                                          from jannat.sst_to_adaptive_export_03012025_1520 saex
                                                          where saex.snapshot_date between '2024-10-31' AND '2024-12-31'
                                                            and saex.type = 'Account Name Customer Bridge')
                , mrpuw_calc AS (select mrp.master_customer_id,
                                        SUM(COALESCE(CASE
                                                         WHEN mrp.bridge = 'Upsell_Cross-sell_Migration'
                                                             THEN mrp.arr_usd_ccfx
                                                         ELSE 0 END, 0)) AS upsell_cross_sell_migration,
--                                        SUM(COALESCE(CASE
--                                                         WHEN mrp.bridge = 'Downsell_Downgrade_Migration'
--                                                             THEN mrp.arr_usd_ccfx
--                                                         ELSE 0 END,
--                                                     0))                 AS downsell_downgrade_migration,
                                        SUM(COALESCE(
                                                CASE WHEN mrp.bridge = 'Price Ramp' THEN mrp.arr_usd_ccfx ELSE 0 END,
                                                0))                      AS price_ramp,
                                        SUM(COALESCE(
                                                CASE WHEN mrp.bridge = 'Price Uplift' THEN mrp.arr_usd_ccfx ELSE 0 END,
                                                0))                      AS price_uplift,
                                        SUM(COALESCE(CASE WHEN mrp.bridge = 'Winback' THEN mrp.arr_usd_ccfx ELSE 0 END,
                                                     0))                 AS winback
                                 from migration_ramp_price_uplift_winback as mrp
                                 group by mrp.master_customer_id)
                , diff_mrpuw AS (select hl.*,
                                        mrpuw_calc.upsell_cross_sell_migration,
--                                        mrpuw_calc.downsell_downgrade_migration,
                                        mrpuw_calc.price_ramp,
                                        mrpuw_calc.price_uplift,
                                        mrpuw_calc.winback,
                                        ABS(hl.abs_diff - mrpuw_calc.upsell_cross_sell_migration)::int AS upsell_cross_sell_migration_diff,
--                                        ABS(hl.abs_diff - mrpuw_calc.downsell_downgrade_migration)::int AS downsell_downgrade_migration_diff,
                                        ABS(hl.abs_diff - mrpuw_calc.price_ramp)::int                  AS price_ramp_diff,
                                        ABS(hl.abs_diff - mrpuw_calc.price_uplift)::int                AS price_uplift_diff,
                                        ABS(hl.abs_diff - mrpuw_calc.winback)::int                     AS winback_diff,
                                        ROUND(CASE
                                                  WHEN hl.abs_diff > 0 THEN
                                                      ABS(mrpuw_calc.upsell_cross_sell_migration::float / hl.abs_diff) *
                                                      100::int
                                                  ELSE 0 END)
                                                                                                       AS upsell_cross_sell_migration_diff_percent,
--                                        ROUND(CASE
--                                                  WHEN hl.abs_diff > 0 THEN
--                                                      ABS(mrpuw_calc.downsell_downgrade_migration::float / hl.abs_diff) *
--                                                      100::int
--                                                  ELSE 0 END)
--                                                                                                        AS downsell_downgrade_migration_diff_percent,
                                        ROUND(CASE
                                                  WHEN hl.abs_diff > 0 THEN
                                                      ABS(mrpuw_calc.price_ramp::float / hl.abs_diff) * 100::int
                                                  ELSE 0 END)
                                                                                                       AS price_ramp_diff_percent,
                                        ROUND(CASE
                                                  WHEN hl.abs_diff > 0 THEN
                                                      ABS(mrpuw_calc.price_uplift::float / hl.abs_diff) * 100
                                                  ELSE 0 END)
                                                                                                       AS price_uplift_diff_percent,
                                        ROUND(CASE
                                                  WHEN hl.abs_diff > 0 THEN
                                                      ABS(mrpuw_calc.winback::float / hl.abs_diff) * 100
                                                  ELSE 0 END)
                                                                                                       AS winback_diff_percent
                                 from historical_labeling hl
                                          LEFT JOIN mrpuw_calc ON hl.mcid = mrpuw_calc.master_customer_id)
                , final_data as (SELECT DISTINCT df.mcid,
                                                 replace(replace(df.opportunity_id::text, '}', ''), '{', '') AS opportunity_id,
                                                 df.name,
                                                 df.booking_amount_usd                                       AS SF_bookings,
                                                 df.arr_usd_ccfx,
                                                 df." ARR LCU TTL Customer Movement ",
                                                 df.celigo_start_date,
                                                 df.diff                                                     AS booking_variance,
                                                 df.abs_diff                                                 AS abs_booking_variance,
                                                 df.bookings_local_currency,
                                                 coalesce(df.prev1_quarter_revenue, 0)                       AS prev1_quarter_revenue,
                                                 coalesce(df.prev2_quarter_revenue, 0)                       AS prev2_quarter_revenue,
                                                 df.upsell_cross_sell_migration,
                                                 df.price_ramp,
                                                 df.price_uplift,
                                                 df.winback,
                                                 CASE
                                                     WHEN (df.label = 'N') AND
                                                          (df.upsell_cross_sell_migration_diff_percent between 90 AND 110)
                                                         THEN 'Migration'
                                                     WHEN (df.label = 'N') AND
                                                          (df.price_ramp_diff_percent between 90 AND 110)
                                                         THEN 'Price Ramp'
----------
                                                     WHEN (df.label = 'N') AND
                                                          (df.price_uplift_diff_percent between 90 AND 110)
                                                         THEN 'Price Uplift'
----------
                                                     WHEN (df.label = 'N') AND
                                                          (df.winback_diff_percent between 90 AND 110)
                                                         THEN 'Winback'
----------
                                                     WHEN (df.label = 'N' or df.label = 'Need to label') THEN
                                                         CASE
                                                             WHEN missing_flag = 'both present'
                                                                 THEN 'Need to label'
 ------------new logic
                                                    when (df.price_ramp+df.price_uplift+df.winback+df.upsell_cross_sell_migration)/df.diff*100
                                                    between 90 and 110 then
                                                    	case  
	                                                    	when greatest(df.price_ramp,df.price_uplift,df.winback,df.upsell_cross_sell_migration)
                                                    		= df.price_ramp then 'Price Ramp'
                                                        	when greatest(df.price_ramp,df.price_uplift,df.winback,df.upsell_cross_sell_migration)
                                                    		= df.price_uplift then 'Price Uplift'
                                                        	when greatest(df.price_ramp,df.price_uplift,df.winback,df.upsell_cross_sell_migration)
                                                    		= df.winback then 'Winback'
                                                        	when greatest(df.price_ramp,df.price_uplift,df.winback,df.upsell_cross_sell_migration)
                                                    		= df.upsell_cross_sell_migration then 'Upsell & Cross-sell Migration'
                                                    	 Else missing_flag
                                                         END
                                                     Else missing_flag
                                                     END
---------
                                                     ELSE label
                                                     END                                                     AS label
                                 FROM diff_mrpuw AS df)
----
             select mcid::text,
                    name::text,
                    opportunity_id::text,
                    CAST(arr_usd_ccfx AS float)          AS          arr_usd_ccfx,
                    cast(" ARR LCU TTL Customer Movement " as float) " ARR LCU TTL Customer Movement ",
                    CAST(SF_bookings AS float)           AS          SF_bookings,
                    NULL::FLOAT                          AS          SF_churns,
                    celigo_start_date::DATE,
                    booking_variance,
                    NULL ::FLOAT                         AS          churn_variance,
                    bookings_local_currency,
                    NULL::float                          as          churn_local_currency,
--        coalesce(current_quarter_revenue, 0),
                    CAST(prev1_quarter_revenue AS float) AS          prev1_quarter_revenue, --last quarter
                    CAST(prev2_quarter_revenue AS float) AS          prev2_quarter_revenue, --last-1 quarter
                    upsell_cross_sell_migration::FLOAT,
--                    downsell_downgrade_migration::FLOAt,
                    price_ramp::FLOAT,
                    NULL::FLOAT                          AS          Reversal,
                    price_uplift::FLOAT,
                    winback::FLOAT,
                    label::TEXT
             from final_data)
-------------------->>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<>>>>
-------------------->>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<>>>>
-------------------->>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<>>>>
        ,
     churn as (
--churn@202501300033
         WITH churn_filtered AS (SELECT *
                                 FROM jannat.churns ch
                                 WHERE EXTRACT(MONTH FROM ch."Renewal Contract Start Date") IN (10, 11, 12)
                                   and replace(ch.amount, ',', '')::float < 0.00)
            , agg_churn AS (SELECT mcid                                    as "Master Customer ID",
                                   SUM(replace(bf.amount, ',', '')::float) AS total_recurring_amount,
                                   array_agg(bf."Opportunity ID (18)")     as opportunity_id,
                                   sum("Renewal Baseline (converted)")        churn_local_currency
                            FROM churn_filtered bf
                            GROUP BY 1)
            , sst_filtered AS (SELECT master_customer_id,
                                      sum(arr_usd_ccfx::float)                as arr_usd_ccfx,
                                      sum(baseline_arr_local_currency::float) as " ARR LCU TTL Customer Movement "
                               FROM jannat.sst_to_adaptive_last_months
                               WHERE "Type" = 'Account Name Customer Bridge'
                                 AND snapshot_date BETWEEN '2024-10-31' AND '2024-12-31'
                               group by 1)
            , latest_celigo AS (SELECT distinct mcid                             as "Master Customer ID",
                                                array_agg("Opportunity ID (18)") AS opportunity_id
                                FROM churn_filtered
                                group by 1)
            , merged_data AS (SELECT b.opportunity_id,
                                     c.*,
                                     b.total_recurring_amount              AS churn_amount_usd,
                                     a.arr_usd_ccfx,
                                     a." ARR LCU TTL Customer Movement ",
                                     COALESCE(b.total_recurring_amount, 0) AS churn_amount_usd_filled,
                                     COALESCE(a.arr_usd_ccfx, 0)           AS arr_usd_ccfx_filled,
                                     COALESCE(b.churn_local_currency, 0)   AS churn_local_currency
                              FROM jannat.customer_deetails_churn c
                                       LEFT JOIN agg_churn b
                                                 ON c.mcid = b."Master Customer ID"
                                       LEFT JOIN sst_filtered a
                                                 ON c.mcid = a.master_customer_id
                                       LEFT JOIN latest_celigo
                                                 ON latest_celigo."Master Customer ID" = c.mcid)
            , merged_with_flags AS (SELECT *,
                                           arr_usd_ccfx_filled - churn_amount_usd_filled      AS diff,
                                           ABS(arr_usd_ccfx_filled - churn_amount_usd_filled) AS abs_diff
                                    FROM merged_data
                                    where coalesce(arr_usd_ccfx_filled, 0) < 0
                                       or coalesce(churn_amount_usd_filled, 0) < 0)
            , churns_final AS (SELECT *,
                                      CASE
                                          WHEN churn_amount_usd_filled < 0
                                              AND arr_usd_ccfx_filled < 0
                                              AND abs_diff < 100 THEN 'Immaterial'
                                          ELSE 'N'
                                          END AS label
                               FROM merged_with_flags
-- where mcid='fa336335-77e2-db11-a16a-0018717a8c82'
         )
-------===========CURRENT MONTH END===========-------===============
            , historical_churn_filtered_current_prev1_quarter AS (SELECT *
                                                                  FROM jannat.his_churn
                                                                  WHERE "Loss Amount (USD)"::float < 0.00
                                                                    AND
                                                                      EXTRACT(MONTH FROM CAST("Renewal Contract Start Date" as date)) IN
                                                                      (7, 8, 9))
            , agg_historical_churn_prev1_quarter
             AS (SELECT hb."Account Name: Master Customer ID" as "Master Customer ID",
                        SUM(hb."Loss Amount (USD)"::float)    AS prev1_quarter_revenue
                 FROM historical_churn_filtered_current_prev1_quarter hb
                 GROUP BY "Master Customer ID")
            , prev1_quarter_churns AS (select
--         ahb."Master Customer ID",
bf.*,
(ahb.prev1_quarter_revenue::float) AS prev1_quarter_revenue
                                       from churns_final bf
                                                LEFT JOIN
                                            agg_historical_churn_prev1_quarter ahb
                                            on bf.mcid = ahb."Master Customer ID")
            , historical_churn_filtered_current_prev2_quarter AS (SELECT *
                                                                  FROM jannat.his_churn
                                                                  WHERE "Loss Amount (USD)"::float < 0.00
                                                                    AND
                                                                      EXTRACT(MONTH FROM CAST("Renewal Contract Start Date" as date)) IN
                                                                      (4, 5, 6))
            , agg_historical_churn_prev2_quarter
             AS (SELECT hb."Account Name: Master Customer ID" as "Master Customer ID",
                        SUM(hb."Loss Amount (USD)"::float)    AS prev2_quarter_revenue
                 FROM historical_churn_filtered_current_prev2_quarter hb
                 GROUP BY "Master Customer ID")
            , prev2_quarter_churns AS (select bf.*,
                                              (ahb.prev2_quarter_revenue::float) AS prev2_quarter_revenue
                                       from prev1_quarter_churns bf
                                                LEFT JOIN
                                            agg_historical_churn_prev2_quarter ahb
                                            on bf.mcid = ahb."Master Customer ID")
            , historical_churns_final AS (select b1.*,
                                                 ABS(b1.arr_usd_ccfx - b1.prev1_quarter_revenue) AS absolute_churn_prev1_diff,
                                                 ABS(b1.arr_usd_ccfx - b1.prev2_quarter_revenue) AS absolute_churn_prev2_diff
                                          from prev2_quarter_churns b1)
            , historical_labeling AS (select hb.mcid,
                                             opportunity_id,
                                             hb.name,
                                             hb.churn_amount_usd,
                                             hb.arr_usd_ccfx,
                                             hb.churn_amount_usd_filled,
                                             hb.arr_usd_ccfx_filled,
                                             hb." ARR LCU TTL Customer Movement ",
                                             hb.diff,
                                             hb.abs_diff,
--                                     hb.current_quarter_revenue,
                                             hb.prev1_quarter_revenue,
                                             hb.prev2_quarter_revenue,
                                             hb.absolute_churn_prev1_diff,
                                             hb.absolute_churn_prev2_diff,
                                             hb.churn_local_currency,
                                             case
                                                 when hb.label = 'N' AND hb.diff <> 0 and
                                                      (hb.prev1_quarter_revenue / hb.diff) * 100 between 95 and 105
                                                     THEN 'SF Loss in prior period'
                                                 when hb.label = 'N' AND hb.diff <> 0 and
                                                      (hb.prev2_quarter_revenue / hb.diff) * 100 between 95 and 105
                                                     THEN 'SF Loss in prior period'
                                                 ELSE hb.label
                                                 END AS label
                                      from historical_churns_final hb)
            , migration_ramp_price_uplift_winback AS (select saex.*,
                                                             case
                                                                 WHEN saex."Bridge_Account" in
                                                                      ('Downgrade - migration', 'Downsell - migration')
                                                                     THEN 'Downsell_Downgrade_Migration'
                                                                 WHEN saex."Bridge_Account" in
                                                                      ('Price Uplift Reversal', 'Up Sell Reversal',
                                                                       'Price Ramp Reversal', 'Cross-sell Reversal')
                                                                     THEN 'Reversal'
                                                                 END AS bridge
                                                      from jannat.sst_to_adaptive_last_months saex
                                                      where saex.snapshot_date between '2024-10-31' AND '2024-12-31'
                                                        and saex."Type" = 'Account Name Customer Bridge')
            , mrpuw_calc AS (select mrp.master_customer_id,
                                    SUM(COALESCE(CASE
                                                     WHEN mrp.bridge = 'Downsell_Downgrade_Migration'
                                                         THEN mrp.arr_usd_ccfx
                                                     ELSE 0 END,
                                                 0)) AS downsell_downgrade_migration,
                                    SUM(COALESCE(CASE WHEN mrp.bridge = 'Reversal' THEN mrp.arr_usd_ccfx ELSE 0 END,
                                                 0)) AS Reversal
                             from migration_ramp_price_uplift_winback as mrp
                             group by mrp.master_customer_id)
            , diff_mrpuw AS (select hl.*,
                                    mrpuw_calc.downsell_downgrade_migration,
                                    mrpuw_calc.Reversal,
--                                     ABS(hl.abs_diff - mrpuw_calc.downsell_downgrade_migration)::int AS downsell_downgrade_migration_diff,
                                    ABS(hl.abs_diff - mrpuw_calc.Reversal)::int AS Reversal_diff,
                                    ROUND(CASE
                                              WHEN hl.abs_diff > 0 THEN
                                                  ABS(mrpuw_calc.downsell_downgrade_migration::float / hl.diff) *
                                                  100::int
                                              ELSE 0 END)
                                                                                AS downsell_downgrade_migration_diff_percent,
                                    ROUND(CASE
                                              WHEN hl.abs_diff > 0 THEN
                                                  ABS(mrpuw_calc.Reversal::float / hl.abs_diff) * 100
                                              ELSE 0 END)
                                                                                AS reversal_diff_percent
                             from historical_labeling hl
                                      LEFT JOIN mrpuw_calc ON hl.mcid = mrpuw_calc.master_customer_id)
            , final_data as (SELECT DISTINCT df.mcid,
                                             replace(replace(df.opportunity_id::text, '}', ''), '{', '') AS opportunity_id,
                                             df.name,
                                             df.churn_amount_usd                                         AS SF_churns,
                                             df.arr_usd_ccfx,
                                             df." ARR LCU TTL Customer Movement ",
                                             df.churn_local_currency,
                                             df.diff                                                     AS churn_variance,
                                             df.abs_diff                                                 AS abs_churn_variance,
                                             coalesce(df.prev1_quarter_revenue, 0)                       AS prev1_quarter_revenue,
                                             coalesce(df.prev2_quarter_revenue, 0)                       AS prev2_quarter_revenue,
                                             df.downsell_downgrade_migration,
                                             df.Reversal,
----------
                                             CASE
----------
                                                 WHEN (df.label = 'N') AND
                                                      (df.downsell_downgrade_migration_diff_percent between 90 AND 110)
                                                     THEN 'Migration'
----------
                                                 WHEN (df.label = 'N') AND
                                                      (df.reversal_diff_percent between 90 AND 110)
                                                     THEN 'Reversal'
----------
                                                 WHEN (df.label = 'N')
                                                     THEN 'Need to label'
---------
                                                 ELSE label
                                                 END                                                     AS label
                             FROM diff_mrpuw AS df)
----
            , warehouse_churn_data_load AS (SELECT master_customer_id,
                                                   extract(month from ss.snapshot_date) as mon,
                                                   sum(arr_usd_ccfx::float)::numeric    as arr_usd_ccfx
                                            FROM jannat.sst_to_adaptive_last_months ss
                                            WHERE ss."Type" = 'Account Name Customer Bridge'
                                              AND snapshot_date BETWEEN '2024-04-01' AND '2024-09-30'
                                              and arr_usd_ccfx::float < 0.0
--                                             and master_customer_id='e1fd96cd-9622-3c56-4ab4-7ba22c6d0f44'
                                            group by 1, 2)
------
         select mcid,
                name,
                opportunity_id,
                CAST(fd.arr_usd_ccfx AS float)                   AS arr_usd_ccfx,
                cast(" ARR LCU TTL Customer Movement " as float) as " ARR LCU TTL Customer Movement ",
                NULL::float                                      AS sf_bookings,
                CAST(SF_churns AS float)                         AS SF_churns,
                NULL::DATE                                       AS celigo_start_date,
                null                                             as booking_variance,
                fd.churn_variance::FLOAT,
                NULL::float                                      as bookings_local_currency,
                churn_local_currency,
                CAST(prev1_quarter_revenue AS float)             AS prev1_quarter_revenue, --last quarter
                CAST(prev2_quarter_revenue AS float)             AS prev2_quarter_revenue, --last-1 quarter
                NULL::FLOAT                                      AS upsell_cross_sell_migration,
                downsell_downgrade_migration::FLOAT,
                NULL::FLOAT                                      AS price_ramp,
                Reversal::FLOAT,
                NULL::FLOAT                                      AS price_uplift,
                NULL::FLOAT                                      AS winback,
                case
	             when churn_variance <>0 and  
	             	(abs(fd.Reversal)+abs(fd.downsell_downgrade_migration))/abs(fd.churn_variance)*100
                            between 90 and 110 then
                            	case  
                                	when greatest(abs(fd.Reversal),abs(fd.downsell_downgrade_migration))
                            		= abs(fd.Reversal) then 'Reversal'
                                	when greatest(abs(fd.Reversal),abs(fd.downsell_downgrade_migration))
                            		= abs(fd.downsell_downgrade_migration) then 'Migration'
                            	 Else fd.label
                                 END                            
                    when 
                        ((ABS(COALESCE(fd.arr_usd_ccfx, 0)) = 0 and
                          ABS(COALESCE(fd.SF_churns, 0)) <> 0)
                            OR
                         (
                             ABS(COALESCE(fd.arr_usd_ccfx, 0)) <> 0 AND
                             ABS(COALESCE(fd.SF_churns, 0)) <> 0
                                 AND ABS(COALESCE(fd.SF_churns, 0)) >
                                     ABS(COALESCE(fd.arr_usd_ccfx, 0))
                             ))
                            AND (
                            fd.churn_variance <> 0
                                and fd.mcid = wh.master_customer_id and
                            ABS(COALESCE(wh.arr_usd_ccfx, 0)) /
                            ABS(COALESCE(fd.churn_variance, 0)) *
                            100 between 95 and 100
                            )
                        THEN
                        CASE
                            WHEN (fd.label = 'N' OR fd.label = 'Need to label' OR fd.label = '')
                                THEN 'DWH loss in prior period'
        ----new logic
                            ELSE fd.label
                            END
                    ELSE fd.label
                    END::TEXT                                    AS label
         from final_data fd
                  LEFT JOIN warehouse_churn_data_load wh on fd.mcid = wh.master_customer_id),
     merged_data AS (SELECT COALESCE(b.mcid, c.mcid)                           AS "MCID",
                            COALESCE(b.name, c.name)                           AS "Name",
                            COALESCE(b.arr_usd_ccfx, c.arr_usd_ccfx,0)           AS "ARR USD TTL Customer Movement",
                            COALESCE(c.SF_churns, 0)                           AS "SF Loss USD",
                            COALESCE(c.churn_variance,0)                         AS "Loss Variance USD",
                            COALESCE(b.SF_bookings, 0)                         AS "SF Bookings USD",
                            COALESCE(b.booking_variance,0)                       AS "Bookings Variance USD",
                            COALESCE(b." ARR LCU TTL Customer Movement ",
                                     c." ARR LCU TTL Customer Movement ",0)      as " ARR LCU TTL Customer Movement ",
                            COALESCE(c.churn_local_currency, 0)                as "SF Loss LCU",
                            COALESCE(c." ARR LCU TTL Customer Movement " - c.churn_local_currency,
                                     0)                                        as "Loss Variance LCU",
                            COALESCE(b.bookings_local_currency, 0)             AS "SF Bookings LCU",
                            COALESCE(b." ARR LCU TTL Customer Movement " - b.bookings_local_currency,
                                     0)                                        as "Bookings Variance LCU",
                            COALESCE(b.celigo_start_date, c.celigo_start_date) AS "Celigo Start Date",
                            COALESCE(b.opportunity_id, c.opportunity_id)       AS "Opportunity ID",
                            COALESCE(c.Reversal, 0)                            AS "Reversal",
                            COALESCE(b.upsell_cross_sell_migration, 0)         AS "(Upsell & Cross-sell Migration)",
                            COALESCE(c.downsell_downgrade_migration, 0)        AS "(Downsell & Downgrade Migration)",
                            COALESCE(b.price_ramp, 0)                          AS "Ramp",
                            COALESCE(b.price_uplift, 0)                        AS "Price Uplift",
                            COALESCE(b.winback, 0)                             AS "Win-Back",
                            COALESCE(c.prev1_quarter_revenue, 0)               AS "Loss in PrevQ1",
                            COALESCE(c.prev2_quarter_revenue, 0)               AS "Loss in PrevQ2",
                            COALESCE(b.prev1_quarter_revenue, 0)               AS "Bookings in PrevQ1",
                            COALESCE(b.prev2_quarter_revenue, 0)               AS "Bookings in PrevQ2",
                            COALESCE(c.label)                                  AS "Final Loss Recon Category",
                            COALESCE(b.label)                                  AS "Final Bookings Recon Category"
FROM bookings b
                              FULL OUTER JOIN churn c ON b.mcid = c.mcid)
SELECT md."MCID",
       md."Name",
       md."ARR USD TTL Customer Movement",
       md."SF Loss USD",
       md."Loss Variance USD",
       md."SF Bookings USD",
       md."Bookings Variance USD",
       md." ARR LCU TTL Customer Movement ",
       md."SF Loss LCU",
       md."Loss Variance LCU",
       md."SF Bookings LCU",
       md."Bookings Variance LCU",
       REPLACE(REPLACE(array_agg(distinct sb.reference_number)::text, '{', ''), '}', '') AS "Reference number",
       REPLACE(REPLACE(array_agg(distinct sb.salesforce_contract_id)::text, '{', ''), '}',
               '')                                                                       AS "Salesforce Contract ID",
       md."Celigo Start Date",
       md."Opportunity ID",
       md."Reversal",
       md."(Upsell & Cross-sell Migration)",
       md."(Downsell & Downgrade Migration)",
       md."Ramp",
       md."Price Uplift",
       md."Win-Back",
       md."Loss in PrevQ1",
       md."Loss in PrevQ2",
       md."Bookings in PrevQ1",
       md."Bookings in PrevQ2",
       md."Final Loss Recon Category",
       md."Final Bookings Recon Category"
FROM merged_data md
         left join
     sandbox_pd.sst_churn_audit_cust sb
     on md."MCID" = sb.master_customer_id
group by 1,
         2,
         3,
         4,
         5,
         6,
         7,
         8,
         9,
         10,
         11,
         12,
         15,
         16,
         17,
         18,
         19,
         20,
         21,
         22,
         23,
         24,
         25,
         26,
         27,
         28;
         
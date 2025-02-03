 --booking@202502040036
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
                , merged_with_flags AS (
                SELECT *,
                                               CASE
                                                   WHEN booking_amount_usd IS NULL AND arr_usd_ccfx IS NOT NULL
--                                           THEN 'ARR not in booking'
                                                       THEN 'Need to label'
                                                   WHEN booking_amount_usd IS NOT NULL AND arr_usd_ccfx IS NULL
--                                           THEN 'Booking not in ARR'
                                                       THEN 'Need to label'
                                                   ELSE 'Need to label'
                                                   END                                              AS missing_flag,
                                               arr_usd_ccfx_filled - booking_amount_usd_filled      AS diff,
                                               ABS(arr_usd_ccfx_filled - booking_amount_usd_filled) AS abs_diff
                                        FROM merged_data
                                        where coalesce(arr_usd_ccfx_filled, 0) > 0
                                           or coalesce(booking_amount_usd_filled, 0) > 0)
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
                                               from merged_with_flags bf
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
                , historical_bookings_final AS (
                									select b1.*,
                                                       ABS(b1.arr_usd_ccfx - b1.prev1_quarter_revenue) AS absolute_booking_prev1_diff,
                                                       ABS(b1.arr_usd_ccfx - b1.prev2_quarter_revenue) AS absolute_booking_prev2_diff
                                                from prev2_quarter_bookings b1)
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
                , diff_mrpuw AS (
                select hl.*,
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
                                 from historical_bookings_final hl
                                          LEFT JOIN mrpuw_calc ON hl.mcid = mrpuw_calc.master_customer_id
                                          )
,final_data as (		
								SELECT DISTINCT df.mcid,
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
                                                     WHEN 
--                                                     (df.label = 'N') AND
                                                          (df.upsell_cross_sell_migration_diff_percent between 90 AND 110)
                                                         THEN 'Migration'
                                                     WHEN 
--                                                     (df.label = 'N') AND
                                                          (df.price_ramp_diff_percent between 90 AND 110)
                                                         THEN 'Price Ramp'
----------
                                                     WHEN 
--                                                     (df.label = 'N') AND
                                                          (df.price_uplift_diff_percent between 90 AND 110)
                                                         THEN 'Price Uplift'
----------
                                                     when
--                                                     (df.label = 'N') AND
                                                          (df.winback_diff_percent between 90 AND 110)
                                                         THEN 'Winback'
----------
--                                                     when
--                                                     (df.label = 'N' or df.label = 'Need to label') THEN
--                                                         CASE
--                                                             WHEN missing_flag = 'both present'
--                                                                 THEN 'Need to label'
------------new logic
                                                    when 
                                                    df.diff <> 0 and 
                                                    (df.price_ramp+df.price_uplift+df.winback+df.upsell_cross_sell_migration)/df.diff*100
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
--                                                     END
---------
                                                     END                                                     AS label
                                 FROM diff_mrpuw AS df
                                 )
---- 
--                , historical_labeling AS (
                select
                 fd.mcid::text,
                    fd.name::text,
                    fd.opportunity_id::text,
                    CAST(fd.arr_usd_ccfx AS float)          AS          arr_usd_ccfx,
                    cast(fd." ARR LCU TTL Customer Movement " as float) " ARR LCU TTL Customer Movement ",
                    CAST(fd.SF_bookings AS float)           AS          SF_bookings,
                    NULL::FLOAT                          AS          SF_churns,
                    fd.celigo_start_date::DATE,
                    fd.booking_variance,
                    0::FLOAT                         AS          churn_variance,
                    fd.bookings_local_currency,
                    0::float                          as          churn_local_currency,
--        coalesce(current_quarter_revenue, 0),
                    coalesce(CAST(fd.prev1_quarter_revenue AS float),0) AS          prev1_quarter_revenue, --last quarter
                    coalesce(CAST(fd.prev2_quarter_revenue AS float),0) AS          prev2_quarter_revenue, --last-1 quarter
                    coalesce(fd.upsell_cross_sell_migration::FLOAT,0) as upsell_cross_sell_migration,
--                    downsell_downgrade_migration::FLOAt,
                    coalesce(fd.price_ramp::FLOAT,0) as price_ramp,
                    0::FLOAT                          AS          Reversal,
                    coalesce(fd.price_uplift::FLOAT,0) price_uplift,
                    coalesce(fd.winback::FLOAT,0) price_uplift,
case
	when fd.label = 'Need to label'
     then 	
       case
		when  
                                                          (hb.booking_amount_usd = 0
		or hb.booking_amount_usd is null)
		and hb.arr_usd_ccfx > 0
		and hb.prev1_quarter_revenue > 0
		and
                                                          hb.absolute_booking_prev1_diff <= 1000
                                                         then 'Booked previously, starts now'
		when  
                                                          (hb.booking_amount_usd = 0
		or hb.booking_amount_usd is null)
		and hb.arr_usd_ccfx > 0
		and hb.prev2_quarter_revenue > 0
		and
                                                          hb.absolute_booking_prev2_diff <= 1000
                                                         then 'Booked previously, starts now'
		when 
                                                booking_amount_usd_filled > 0
		and arr_usd_ccfx_filled > 0
		and abs_diff < 1000 then 'Immaterial'
		else
        	case
			when   
                                                        fd.celigo_start_date >= '2024-12-26'
			--bnsl_date
			and (fd.arr_usd_ccfx = 0
			or fd.arr_usd_ccfx is null)
                                                            then 'Booked now, starts later'
			else 'Need to label'
			end
		end
	else fd.label end as label
                                          from 
                                          final_data fd left join
                                          historical_bookings_final hb
											on fd.mcid = hb.mcid
                                          --                                         
-- )
                                          
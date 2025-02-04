-- final_merge_data@202502052359
with final_output as(
with bookings as (
--booking@202502052359
 with booking_filtered as (
select
	*
from
	jannat.bookings
where
	"Month # - Close Date" in (1))
                ,
agg_booking as (
select
	"Master Customer ID",
   SUM(BTRIM(replace(REPLACE("Recurring Software Amount Change (converted)",'USD ',''),',',''))::float) as total_recurring_amount,
	sum(BTRIM(replace(right("Recurring Software Amount Change", 
      length("Recurring Software Amount Change") - 3), ',',
                                                           ''))::float) bookings_local_currency,
	array_agg("Opportunity ID") as opportunity_id
from
	booking_filtered bf
group by
	1
	)
                ,
sst_filtered as (
select
	master_customer_id,
	sum("ARR USD Converted 2025"::float) as arr_usd_ccfx,
	sum(baseline_arr_local_currency::float) as " ARR LCU TTL Customer Movement "
from
	jannat.sst_adaptive_new1
where
	"Type" = 'Account Name Customer Bridge'
	and snapshot_date between '2025-01-01' and '2025-03-31'
group by
	1
             )
                ,
uniue_bookings_date_mcid_data as (
select
	distinct "Master Customer ID",
	"Celigo[AT]_Start Date" AS "Celigo[AT]_Start Date",
	"Opportunity ID"
from
	booking_filtered)
                ,
latest_celigo as (
select
	"Master Customer ID",
	array_agg("Opportunity ID") as opportunity_id,
	MAX("Celigo[AT]_Start Date") as latest_celigo_start_date
from
	uniue_bookings_date_mcid_data
group by
	1)
                ,
merged_data as (
select
--	c.mcid as mcid,
	b.opportunity_id,
	c.*,
	b.total_recurring_amount as booking_amount_usd,
	a.arr_usd_ccfx,
	a." ARR LCU TTL Customer Movement ",
	coalesce(b.total_recurring_amount,
	0) as booking_amount_usd_filled,
	coalesce(a.arr_usd_ccfx,
	0) as arr_usd_ccfx_filled,
	coalesce(b.bookings_local_currency,
	0) as bookings_local_currency,
	latest_celigo.latest_celigo_start_date as celigo_start_date
from
	jannat.customer_details1 c
left join agg_booking b
                                                     on
	c.mcid = b."Master Customer ID"
left join sst_filtered a
                                                     on
	c.mcid = a.master_customer_id
left join latest_celigo
                                                     on
	latest_celigo."Master Customer ID" = c.mcid
	)
                ,
merged_with_flags as (
select
	*,
	case
		when booking_amount_usd is null
			and arr_usd_ccfx is not null
        then 'Need to label'
			when booking_amount_usd is not null
			and arr_usd_ccfx is null
         then 'Need to label'
			else 'Need to label'
		end as missing_flag,
		arr_usd_ccfx_filled - booking_amount_usd_filled as diff,
		ABS(arr_usd_ccfx_filled - booking_amount_usd_filled) as abs_diff
	from
		merged_data
	where
		coalesce(arr_usd_ccfx_filled,
		0) > 0
			or coalesce(booking_amount_usd_filled,
			0) > 0)
                     ,
historical_booking_filtered_current_quarter as (
select
	*
from
	jannat.current_month
where
	"Month # - Close Date" in (1))
-------===========CURRENT MONTH START===========-------==============
                ,
agg_historical_booking_current_quarter as (
select
	"Master Customer ID",
--	SUM(hb.recurring_revenue::float) as "current_quarter_revenue"
	SUM(BTRIM(replace(REPLACE("Recurring Software Amount Change (converted)",'USD ',''),',',''))::float) as "current_quarter_revenue"
from
	historical_booking_filtered_current_quarter hb
group by
	"Master Customer ID")
                ,
current_quarter_bookings as (
select
	bf.*,
	coalesce(ahb.current_quarter_revenue,
	0) as current_quarter_revenue
from
	merged_with_flags bf
left join
agg_historical_booking_current_quarter ahb
 on
	bf.mcid = ahb."Master Customer ID")
-------===========CURRENT MONTH END===========-------===============
                ,
historical_booking_filtered_current_prev1_quarter as (
select
	*
from
	jannat.previous_quarter1
where
	"Month # - Close Date" in (10,11,12))
 ,
 agg_historical_booking_prev1_quarter as (
select
	"Master Customer ID",
--	SUM(hb.recurring_revenue::float) as prev1_quarter_revenue
	SUM(BTRIM(replace(REPLACE("Recurring Software Amount Change (converted)",'USD ',''),',',''))::float) as prev1_quarter_revenue
from
	historical_booking_filtered_current_prev1_quarter hb
group by
	"Master Customer ID")
                ,
prev1_quarter_bookings as (
select
	--         ahb."Master Customer ID",
	bf.*,
	coalesce(ahb.prev1_quarter_revenue::float,
	0) as prev1_quarter_revenue
from
	current_quarter_bookings bf
left join
agg_historical_booking_prev1_quarter ahb
on
	bf.mcid = ahb."Master Customer ID")
                ,
historical_booking_filtered_current_prev2_quarter as (
select
	*
from
	jannat.previous_quarter2
where
	"Month # - Close Date" in (7,8,9))
                ,
agg_historical_booking_prev2_quarter as (
select
	"Master Customer ID",
--	SUM(hb.recurring_revenue::float) as prev2_quarter_revenue
	SUM(BTRIM(replace(REPLACE("Recurring Software Amount Change (converted)",'USD ',''),',',''))::float)as prev2_quarter_revenue
from
	historical_booking_filtered_current_prev2_quarter hb
group by
	"Master Customer ID")
                ,
prev2_quarter_bookings as (
select
	bf.*,
	coalesce(ahb.prev2_quarter_revenue::float,
	0) as prev2_quarter_revenue
from
	prev1_quarter_bookings bf
left join
 agg_historical_booking_prev2_quarter ahb
  on
	bf.mcid = ahb."Master Customer ID")
                ,
historical_bookings_final as (
select
	b1.*,
	ABS(b1.arr_usd_ccfx - b1.prev1_quarter_revenue) as absolute_booking_prev1_diff,
	ABS(b1.arr_usd_ccfx - b1.prev2_quarter_revenue) as absolute_booking_prev2_diff
from
	prev2_quarter_bookings b1)
             ,
migration_ramp_price_uplift_winback as (
select
	saex.*,
	case
		when saex.bridge_account in
         ('Cross-sell - migration','Up Sell - migration')
         then 'Upsell_Cross-sell_Migration'
		when saex.bridge_account in 
		('Win back Downgrade', 'Win back Downsell','Winback','Lapsed Renewal')
        then 'Winback'
		when saex.bridge_account = 'Price Ramp' 
		then 'Price Ramp'
		when saex.bridge_account = 'Price Uplift'
        then 'Price Uplift'
	end as bridge
from
	jannat.sst_adaptive_new1 saex
where
	saex.snapshot_date between '2025-01-01' and '2025-03-31'
	and saex."Type" = 'Account Name Customer Bridge')
                ,
mrpuw_calc as (
select
	mrp.master_customer_id,
	SUM(coalesce(
	case
        when mrp.bridge = 'Upsell_Cross-sell_Migration'
        then mrp.arr_usd_ccfx
         else 0 end, 0)) as upsell_cross_sell_migration,
	SUM(coalesce(
      case when mrp.bridge = 'Price Ramp' then mrp.arr_usd_ccfx else 0 end,
      0)) as price_ramp,
	SUM(coalesce(
     case when mrp.bridge = 'Price Uplift' then mrp.arr_usd_ccfx else 0 end,
     0)) as price_uplift,
	SUM(coalesce(case when mrp.bridge = 'Winback' then mrp.arr_usd_ccfx else 0 end,
    0)) as winback
from
	migration_ramp_price_uplift_winback as mrp
group by
	mrp.master_customer_id)
                ,
diff_mrpuw as (
select
	hl.*,
	mrpuw_calc.upsell_cross_sell_migration,
	mrpuw_calc.price_ramp,
	mrpuw_calc.price_uplift,
	mrpuw_calc.winback,
	ABS(hl.abs_diff - mrpuw_calc.upsell_cross_sell_migration)::int as upsell_cross_sell_migration_diff,
	ABS(hl.abs_diff - mrpuw_calc.price_ramp)::int as price_ramp_diff,
	ABS(hl.abs_diff - mrpuw_calc.price_uplift)::int as price_uplift_diff,
	ABS(hl.abs_diff - mrpuw_calc.winback)::int as winback_diff,
	ROUND(case
		when hl.abs_diff > 0 then
        ABS(mrpuw_calc.upsell_cross_sell_migration::float / hl.abs_diff) *
                                                      100::int
		else 0
	end) as upsell_cross_sell_migration_diff_percent,
     ROUND(case
		when hl.abs_diff > 0 then
                                                      ABS(mrpuw_calc.price_ramp::float / hl.abs_diff) * 100::int
		else 0
	end)
                                                                                                       as price_ramp_diff_percent,
	ROUND(case
		when hl.abs_diff > 0 then
                                                      ABS(mrpuw_calc.price_uplift::float / hl.abs_diff) * 100
		else 0
	end)
                                                                                                       as price_uplift_diff_percent,
	ROUND(case
		when hl.abs_diff > 0 then
                                                      ABS(mrpuw_calc.winback::float / hl.abs_diff) * 100
		else 0
	end)
                                                                                                       as winback_diff_percent
from
	historical_bookings_final hl
left join mrpuw_calc on
	hl.mcid = mrpuw_calc.master_customer_id
                                          )
,
final_data as (
select
	distinct df.mcid,
	replace(replace(df.opportunity_id::text,
	'}',
	''),
	'{',
	'') as opportunity_id,
	df.name,
	df.booking_amount_usd as SF_bookings,
	df.arr_usd_ccfx,
	df." ARR LCU TTL Customer Movement ",
	df.celigo_start_date,
	df.diff as booking_variance,
	df.abs_diff as abs_booking_variance,
	df.bookings_local_currency,
	coalesce(df.prev1_quarter_revenue,
	0) as prev1_quarter_revenue,
	coalesce(df.prev2_quarter_revenue,
	0) as prev2_quarter_revenue,
	df.upsell_cross_sell_migration,
	df.price_ramp,
	df.price_uplift,
	df.winback,
	case
		when
		--                                                     (df.label = 'N') AND
                                                          (df.upsell_cross_sell_migration_diff_percent between 90 and 110)
                                                         then 'Migration'
		when
		--                                                     (df.label = 'N') AND
                                                          (df.price_ramp_diff_percent between 90 and 110)
                                                         then 'Price Ramp'
		----------
		when
		--                                                     (df.label = 'N') AND
                                                          (df.price_uplift_diff_percent between 90 and 110)
                                                         then 'Price Uplift'
		----------
		when
		--                                                     (df.label = 'N') AND
                                                          (df.winback_diff_percent between 90 and 110)
                                                         then 'Winback'
		----------
		--                                                     when
		--                                                     (df.label = 'N' or df.label = 'Need to label') THEN
		--                                                         CASE
		--                                                             WHEN missing_flag = 'both present'
		--                                                                 THEN 'Need to label'
		------------new logic
		when 
                                                    df.diff <> 0
			and 
                                                    (df.price_ramp + df.price_uplift + df.winback + df.upsell_cross_sell_migration)/ df.diff * 100
                                                    between 90 and 110 then
                                                    	case
				when greatest(df.price_ramp,
				df.price_uplift,
				df.winback,
				df.upsell_cross_sell_migration)
                                                    		= df.price_ramp then 'Price Ramp'
				when greatest(df.price_ramp,
				df.price_uplift,
				df.winback,
				df.upsell_cross_sell_migration)
                                                    		= df.price_uplift then 'Price Uplift'
				when greatest(df.price_ramp,
				df.price_uplift,
				df.winback,
				df.upsell_cross_sell_migration)
                                                    		= df.winback then 'Winback'
				when greatest(df.price_ramp,
				df.price_uplift,
				df.winback,
				df.upsell_cross_sell_migration)
                                                    		= df.upsell_cross_sell_migration then 'Migration'
				else missing_flag
			end
			else missing_flag
			--                                                     END
			---------
		end as label
	from
		diff_mrpuw as df
                                 )
---- 
--                , historical_labeling AS (
                select
	fd.mcid::text,
	fd.name::text,
	fd.opportunity_id::text,
	cast(fd.arr_usd_ccfx as float) as arr_usd_ccfx,
	cast(fd." ARR LCU TTL Customer Movement " as float) " ARR LCU TTL Customer Movement ",
	cast(fd.SF_bookings as float) as SF_bookings,
	null::FLOAT as SF_churns,
	fd.celigo_start_date::DATE,
	fd.booking_variance,
	0::FLOAT as churn_variance,
	fd.bookings_local_currency,
	0::float as churn_local_currency,
	--        coalesce(current_quarter_revenue, 0),
                    coalesce(cast(fd.prev1_quarter_revenue as float),
	0) as prev1_quarter_revenue,
	--last quarter
                    coalesce(cast(fd.prev2_quarter_revenue as float),
	0) as prev2_quarter_revenue,
	--last-1 quarter
                    coalesce(fd.upsell_cross_sell_migration::FLOAT,
	0) as upsell_cross_sell_migration,
	--                    downsell_downgrade_migration::FLOAt,
                    coalesce(fd.price_ramp::FLOAT,
	0) as price_ramp,
	0::FLOAT as Reversal,
	coalesce(fd.price_uplift::FLOAT,
	0) price_uplift,
	coalesce(fd.winback::FLOAT,
	0) winback,
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
                                                         then 'Booking Deferral'
			when  
                                                          (hb.booking_amount_usd = 0
				or hb.booking_amount_usd is null)
			and hb.arr_usd_ccfx > 0
			and hb.prev2_quarter_revenue > 0
			and
                                                          hb.absolute_booking_prev2_diff <= 1000
                                                         then 'Booking Deferral'
			when 
            booking_amount_usd_filled > 0
			and arr_usd_ccfx_filled > 0
			and abs_diff < 1000 then 'Immaterial'
			else
        	case
				when   
                  fd.celigo_start_date >= '2025-01-26'
				--bnsl_date
				and (fd.arr_usd_ccfx = 0
					or fd.arr_usd_ccfx is null)
                                                            then 'Booking Lag'
				else 'Need to label'
			end
		end
		else fd.label
	end as label
from
	final_data fd
left join
                                          historical_bookings_final hb
											on
	fd.mcid = hb.mcid
	--                                         
)
,churn as (
--churn@202502052359
 with churn_filtered as (
select
	*
from
	jannat.churn ch
where
	extract(month
from
	ch."Renewal Contract Start Date"::date) in (1)
	and "Churn Amount(USD)"< 0.00)
            ,
agg_churn as (
select
	mcid as "Master Customer ID",
--	SUM(replace(bf."Churn Amount(USD)", ',', '')::float) as total_recurring_amount,
	sum(bf."Churn Amount(USD)") as total_recurring_amount,
	array_agg(bf."Opportunity ID") as opportunity_id,
	sum("Renewal Baseline (converted)") churn_local_currency
from
	churn_filtered bf
group by
	1)
            ,
sst_filtered as (
select
	master_customer_id,
	sum("ARR USD Converted 2025"::float) as arr_usd_ccfx,
	sum(baseline_arr_local_currency::float) as " ARR LCU TTL Customer Movement "
from
	jannat.sst_adaptive_new1
where
	"Type" = 'Account Name Customer Bridge'
	and snapshot_date between '2025-01-01' and '2025-03-31'
group by
	1)
            ,
latest_celigo as (
select
	distinct mcid as "Master Customer ID",
	array_agg("Opportunity ID (18)") as opportunity_id
from
	churn_filtered
group by
	1)
            ,
merged_data as (
select
	b.opportunity_id,
	c.*,
	b.total_recurring_amount as churn_amount_usd,
	a.arr_usd_ccfx,
	a." ARR LCU TTL Customer Movement ",
	coalesce(b.total_recurring_amount,
	0) as churn_amount_usd_filled,
	coalesce(a.arr_usd_ccfx,
	0) as arr_usd_ccfx_filled,
	coalesce(b.churn_local_currency,
	0) as churn_local_currency
from
	jannat.customer_details1 c
left join agg_churn b
                                                 on
	c.mcid = b."Master Customer ID"
left join sst_filtered a
                                                 on
	c.mcid = a.master_customer_id
left join latest_celigo
                                                 on
	latest_celigo."Master Customer ID" = c.mcid)
            ,
merged_with_flags as (
select
	*,
	arr_usd_ccfx_filled - churn_amount_usd_filled as diff,
	ABS(arr_usd_ccfx_filled - churn_amount_usd_filled) as abs_diff
from
	merged_data
where
	coalesce(arr_usd_ccfx_filled,
	0) < 0
		or coalesce(churn_amount_usd_filled,
		0) < 0)
           ,
migration_ramp_price_uplift_winback as (
select
	saex.*,
	case
		when saex."bridge_account" in
                                                                      ('Downgrade - migration', 'Downsell - migration')
                                                                     then 'Downsell_Downgrade_Migration'
		when saex."bridge_account" in
                                                                      ('Price Uplift Reversal', 'Up Sell Reversal',
                                                                       'Price Ramp Reversal', 'Cross-sell Reversal')
                                                                     then 'Reversal'
	end as bridge
from
	jannat.sst_adaptive_new1 saex
where
	saex.snapshot_date between '2025-01-01' and '2025-03-31'
	and saex."Type" = 'Account Name Customer Bridge')
            ,
mrpuw_calc as (
select
	mrp.master_customer_id,
	SUM(coalesce(case
                                                     when mrp.bridge = 'Downsell_Downgrade_Migration'
                                                         then mrp.arr_usd_ccfx
                                                     else 0 end,
                                                 0)) as downsell_downgrade_migration,
	SUM(coalesce(case when mrp.bridge = 'Reversal' then mrp.arr_usd_ccfx else 0 end,
                                                 0)) as Reversal
from
	migration_ramp_price_uplift_winback as mrp
group by
	mrp.master_customer_id)
            ,
diff_mrpuw as (
select
	hl.*,
	mrpuw_calc.downsell_downgrade_migration,
	mrpuw_calc.Reversal,
	--                                     ABS(hl.abs_diff - mrpuw_calc.downsell_downgrade_migration)::int AS downsell_downgrade_migration_diff,
	ABS(hl.abs_diff - mrpuw_calc.Reversal)::int as Reversal_diff,
	ROUND(case
		when hl.abs_diff > 0 then
                                                  ABS(mrpuw_calc.downsell_downgrade_migration::float / hl.diff) *
                                                  100::int
		else 0
	end)
                                                                                as downsell_downgrade_migration_diff_percent,
	ROUND(case
		when hl.abs_diff > 0 then
                                                  ABS(mrpuw_calc.Reversal::float / hl.abs_diff) * 100
		else 0
	end)
                                                                                as reversal_diff_percent
from
	merged_with_flags hl
left join mrpuw_calc on
	hl.mcid = mrpuw_calc.master_customer_id)
    ,
final_data as (
select
	distinct df.mcid,
	replace(replace(df.opportunity_id::text,
	'}',
	''),
	'{',
	'') as opportunity_id,
	df.name,
	df.churn_amount_usd as SF_churns,
	df.arr_usd_ccfx,
	df." ARR LCU TTL Customer Movement ",
	df.churn_local_currency,
	df.diff as churn_variance,
	df.abs_diff as abs_churn_variance,
	df.downsell_downgrade_migration,
	df.Reversal,
	----------
                                             case
		----------
                                                 when
		--                                                 (df.label = 'N') AND
                                                      (df.downsell_downgrade_migration_diff_percent between 90 and 110)
                                                     then 'Migration'
		----------
		when
		--                                                 (df.label = 'N') AND
                                                      (df.reversal_diff_percent between 90 and 110)
                                                     then 'Reversal'
		----------
		--                                                 WHEN 
		--                                                 (df.label = 'N')
		--                                                     THEN 'Need to label'
		---------
		when diff <> 0
			and  
								             	(abs(df.Reversal)+ abs(df.downsell_downgrade_migration))/ abs(df.diff)* 100
							                            between 90 and 110 then
							                            	case  
							                                	when greatest(abs(df.Reversal),
				abs(df.downsell_downgrade_migration))
							                            		= abs(df.Reversal) then 'Reversal'
				when greatest(abs(df.Reversal),
				abs(df.downsell_downgrade_migration))
							                            		= abs(df.downsell_downgrade_migration) then 'Migration'
				else 'Need to label'
			end
			else 'Need to label'
		end as label
	from
		diff_mrpuw as df
                             )
--   , historical_labeling AS (
            select
	hb.mcid,
	hb.opportunity_id,
	hb.name,
	hb.SF_churns as churn_amount_usd,
	hb.arr_usd_ccfx,
	coalesce(hb.SF_churns,0) as churn_amount_usd_filled,
	coalesce(hb.arr_usd_ccfx,0) as arr_usd_ccfx_filled,
	hb." ARR LCU TTL Customer Movement ",
	churn_variance as diff,
	ABS(churn_variance) as abs_diff,
	hb.churn_local_currency,
	SF_churns,
	churn_variance ,
	null as celigo_start_date,
	downsell_downgrade_migration,
	reversal,
	case
		when (hb.label = 'N'
			or hb.label = 'Need to label'
			or hb.label = '')
		and coalesce(hb.SF_churns,0) < 0
		and coalesce(hb.arr_usd_ccfx,0) < 0
		and ABS(churn_variance) < 100 
	then 'Immaterial'
	else hb.label
	end as label
from
	final_data hb
  )
   ,merged_data AS (
   SELECT COALESCE(b.mcid, c.mcid)                           AS "MCID",
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
                            COALESCE(b.celigo_start_date::text, c.celigo_start_date::text)::date AS "Celigo Start Date",
                            COALESCE(b.opportunity_id, c.opportunity_id::text)       AS "Opportunity ID",
                            COALESCE(c.Reversal, 0)                            AS "Reversal",
                            COALESCE(b.upsell_cross_sell_migration, 0)         AS "(Upsell & Cross-sell Migration)",
                            COALESCE(c.downsell_downgrade_migration, 0)        AS "(Downsell & Downgrade Migration)",
                            COALESCE(b.price_ramp, 0)                          AS "Ramp",
                            COALESCE(b.price_uplift, 0)                        AS "Price Uplift",
                            COALESCE(b.winback, 0)                             AS "Win-Back",
                            COALESCE(b.prev1_quarter_revenue, 0)               AS "Bookings in PrevQ1",
                            COALESCE(b.prev2_quarter_revenue, 0)               AS "Bookings in PrevQ2",
                            COALESCE(c.label)                                  AS "Final Loss Recon Category",
                            COALESCE(b.label)                                  AS "Final Bookings Recon Category"
FROM bookings b
                              FULL OUTER JOIN churn c ON b.mcid = c.mcid
  )
select
	   md."MCID",
       md."Name",
       md."ARR USD TTL Customer Movement"::float,
       md."SF Loss USD"::float,
       md."Loss Variance USD"::float,
       md."SF Bookings USD"::float,
       md."Bookings Variance USD"::float,
       md." ARR LCU TTL Customer Movement "::float,
       md."SF Loss LCU"::float,
       md."Loss Variance LCU"::float,
       md."SF Bookings LCU"::float,
       md."Bookings Variance LCU"::float,
       REPLACE(REPLACE(array_agg(distinct sb.reference_number)::text, '{', ''), '}', '') AS "Reference number",
       REPLACE(REPLACE(array_agg(distinct sb.salesforce_contract_id)::text, '{', ''), '}',
               '')                                                                       AS "Salesforce Contract ID",
       md."Celigo Start Date"::date,
       replace(md."Opportunity ID",'NULL','') as "Opportunity ID",
       md."Reversal"::float,
       md."(Upsell & Cross-sell Migration)"::float,
       md."(Downsell & Downgrade Migration)"::float,
       md."Ramp"::float,
       md."Price Uplift"::float,
       md."Win-Back"::float,
       md."Bookings in PrevQ1"::float,
       md."Bookings in PrevQ2"::float,
       md."Final Loss Recon Category",
       md."Final Bookings Recon Category"
FROM merged_data md
         left join
     sandbox_pd.sst_churn_audit_cust sb
     on md."MCID" = sb.master_customer_id
     and 
     evaluation_period ='2025M01'
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
--     13,
--     14,
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
         26
         )
         select 
       "MCID",
       "Name",
       "ARR USD TTL Customer Movement"::numeric,
       "SF Loss USD"::numeric,
       "Loss Variance USD"::numeric,
       "SF Bookings USD"::numeric,
       "Bookings Variance USD"::numeric,
       " ARR LCU TTL Customer Movement "::numeric,
       "SF Loss LCU"::numeric,
       "Loss Variance LCU"::numeric,
      "SF Bookings LCU"::numeric,
       "Bookings Variance LCU"::numeric,
       case 
       	when "Reference number"='NULL' then ' '
       	else "Reference number"
       end"Reference number",
       case 
       	when "Salesforce Contract ID"= 'NULL' then ' '
       	else "Salesforce Contract ID"
       end "Salesforce Contract ID",
       "Celigo Start Date"::date,
      "Opportunity ID",
       "Reversal"::numeric,
       "(Upsell & Cross-sell Migration)"::numeric,
       "(Downsell & Downgrade Migration)"::numeric,
      "Ramp"::numeric,
       "Price Uplift"::numeric,
      "Win-Back"::numeric,
       "Bookings in PrevQ1"::numeric,
       "Bookings in PrevQ2"::numeric,
       "Final Loss Recon Category",
       "Final Bookings Recon Category"
       from
       final_output
        ;
       
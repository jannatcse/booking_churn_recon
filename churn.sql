--churn@202502040041
 with churn_filtered as (
select
	*
from
	jannat.churns ch
where
	extract(month
from
	ch."Renewal Contract Start Date") in (10, 11, 12)
	and replace(ch.amount,
	',',
	'')::float < 0.00)
            ,
agg_churn as (
select
	mcid as "Master Customer ID",
	SUM(replace(bf.amount, ',', '')::float) as total_recurring_amount,
	array_agg(bf."Opportunity ID (18)") as opportunity_id,
	sum("Renewal Baseline (converted)") churn_local_currency
from
	churn_filtered bf
group by
	1)
            ,
sst_filtered as (
select
	master_customer_id,
	sum(arr_usd_ccfx::float) as arr_usd_ccfx,
	sum(baseline_arr_local_currency::float) as " ARR LCU TTL Customer Movement "
from
	jannat.sst_to_adaptive_last_months
where
	"Type" = 'Account Name Customer Bridge'
	and snapshot_date between '2024-10-31' and '2024-12-31'
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
	jannat.customer_deetails_churn c
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
historical_churn_filtered_current_prev1_quarter as (
select
	*
from
	jannat.his_churn
where
	"Loss Amount (USD)"::float < 0.00
	and
                                                                      extract(month
from
	cast("Renewal Contract Start Date" as date)) in
                                                                      (7, 8, 9))
            ,
agg_historical_churn_prev1_quarter
             as (
select
	hb."Account Name: Master Customer ID" as "Master Customer ID",
	SUM(hb."Loss Amount (USD)"::float) as prev1_quarter_revenue
from
	historical_churn_filtered_current_prev1_quarter hb
group by
	"Master Customer ID")
            ,
prev1_quarter_churns as (
select
	--         ahb."Master Customer ID",
	bf.*,
	(ahb.prev1_quarter_revenue::float) as prev1_quarter_revenue
from
	merged_with_flags bf
left join
                                            agg_historical_churn_prev1_quarter ahb
                                            on
	bf.mcid = ahb."Master Customer ID")
            ,
historical_churn_filtered_current_prev2_quarter as (
select
	*
from
	jannat.his_churn
where
	"Loss Amount (USD)"::float < 0.00
	and
                                                                      extract(month
from
	cast("Renewal Contract Start Date" as date)) in
                                                                      (4, 5, 6))
            ,
agg_historical_churn_prev2_quarter
             as (
select
	hb."Account Name: Master Customer ID" as "Master Customer ID",
	SUM(hb."Loss Amount (USD)"::float) as prev2_quarter_revenue
from
	historical_churn_filtered_current_prev2_quarter hb
group by
	"Master Customer ID")
            ,
prev2_quarter_churns as (
select
	bf.*,
	(ahb.prev2_quarter_revenue::float) as prev2_quarter_revenue
from
	prev1_quarter_churns bf
left join
                                            agg_historical_churn_prev2_quarter ahb
                                            on
	bf.mcid = ahb."Master Customer ID")
            ,
historical_churns_final as (
select
	b1.*,
	ABS(b1.arr_usd_ccfx - b1.prev1_quarter_revenue) as absolute_churn_prev1_diff,
	ABS(b1.arr_usd_ccfx - b1.prev2_quarter_revenue) as absolute_churn_prev2_diff
from
	prev2_quarter_churns b1
                                          )
                      ,
migration_ramp_price_uplift_winback as (
select
	saex.*,
	case
		when saex."Bridge_Account" in
                                                                      ('Downgrade - migration', 'Downsell - migration')
                                                                     then 'Downsell_Downgrade_Migration'
		when saex."Bridge_Account" in
                                                                      ('Price Uplift Reversal', 'Up Sell Reversal',
                                                                       'Price Ramp Reversal', 'Cross-sell Reversal')
                                                                     then 'Reversal'
	end as bridge
from
	jannat.sst_to_adaptive_last_months saex
where
	saex.snapshot_date between '2024-10-31' and '2024-12-31'
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
	historical_churns_final hl
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
	coalesce(df.prev1_quarter_revenue,
	0) as prev1_quarter_revenue,
	coalesce(df.prev2_quarter_revenue,
	0) as prev2_quarter_revenue,
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
            ,
warehouse_churn_data_load as (
select
	master_customer_id as mcid,
	extract(month
from
	ss.snapshot_date) as mon,
	sum(arr_usd_ccfx::float)::numeric as arr_usd_ccfx
from
	jannat.sst_to_adaptive_last_months ss
where
	ss."Type" = 'Account Name Customer Bridge'
	and snapshot_date between '2024-04-01' and '2024-09-30'
	and arr_usd_ccfx::float < 0.0
	--                                             and master_customer_id='e1fd96cd-9622-3c56-4ab4-7ba22c6d0f44'
group by
	1,
	2)
----
--            , historical_labeling AS (
            select
	hb.mcid,
	hb.opportunity_id,
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
		when fd.label = 'Need to label'
		and hb.diff <> 0
		and
                                                      (hb.prev1_quarter_revenue / hb.diff) * 100 between 95 and 105
                                                     then 'SF Loss in prior period'
		when fd.label = 'Need to label'
		and hb.diff <> 0
		and
                                                      (hb.prev2_quarter_revenue / hb.diff) * 100 between 95 and 105
                                                     then 'SF Loss in prior period'
		when 
                        ((ABS(coalesce(fd.arr_usd_ccfx,
		0)) = 0
			and
                          ABS(coalesce(fd.SF_churns,
			0)) <> 0)
			or
                         (
                             ABS(coalesce(fd.arr_usd_ccfx,
			0)) <> 0
				and
                             ABS(coalesce(fd.SF_churns,
				0)) <> 0
					and ABS(coalesce(fd.SF_churns,
					0)) >
                                     ABS(coalesce(fd.arr_usd_ccfx,
					0))
                             ))
		and (
                            fd.churn_variance <> 0
			and fd.mcid = wd.mcid
			and
                            ABS(coalesce(wd.arr_usd_ccfx,
			0)) /
                            ABS(coalesce(fd.churn_variance,
			0)) *
                            100 between 95 and 100
                            )
                        then
	                        case
			when (fd.label = 'Need to label'
				or fd.label = '')
	                                then 'DWH loss in prior period'
			else fd.label
		end
		when (fd.label = 'N'
			or fd.label = 'Need to label'
			or fd.label = '')
		and churn_amount_usd_filled < 0
		and arr_usd_ccfx_filled < 0
		and abs_diff < 100 then 'Immaterial'
		else fd.label
	end as label
from
	final_data fd
left join
                                      historical_churns_final hb
                                      on
	hb.mcid = fd.mcid
left join warehouse_churn_data_load wd on
	wd.mcid = fd.mcid
	--                                      )

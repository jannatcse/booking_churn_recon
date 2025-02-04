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

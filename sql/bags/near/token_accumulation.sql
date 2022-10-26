--------------------------------bridging
with token_prices as (
	select distinct token_contract, 
      TRUNC(TIMESTAMP,'hour') as timestamp_h, 
      avg(price_usd) as price_usd 
  	from near.core.fact_prices
  	where timestamp >= (current_date - 90)
  	group by 1,2
),
near_prices as (
	select 
      TRUNC(TIMESTAMP,'hour') as timestamp_h, 
      avg(price_usd) as price_usd 
  	from near.core.fact_prices
  	where timestamp >= (current_date - 90)
  	AND symbol = 'wNEAR'
  	group by 1
),
nte_erc20_transactions as (
select 
a.block_timestamp,
a.tx_hash, 
b.tx_signer as sender,
b.tx_receiver as token_id,
parse_json(a.args):amount::number as amount, 
lower(concat('0x',parse_json(a.args):recipient::string)) as eth_recipient
from "NEAR"."CORE"."FACT_ACTIONS_EVENTS_FUNCTION_CALL" a
inner join (select tx_hash, tx_receiver, tx_signer
            from "NEAR"."CORE"."FACT_TRANSACTIONS" 
                    where tx_receiver ilike ('%.factory.bridge.near')   
                    and tx_receiver not in ('metadata.factory.bridge.near', 'controller.factory.bridge.near') 
                    and tx_status = 'Success') b
on a.tx_hash = b.tx_hash
where a.method_name = 'withdraw'
  and block_timestamp >= (current_date - 90)
),
nte_erc20_totals as (
select 
block_timestamp,
tx_hash,
sender,
token_id,
(a.amount/pow(10,b.decimals)) as token_amount,
eth_recipient,
b.symbol,
b.decimals,
(token_amount*c.price_usd) as usd_amt
from nte_erc20_transactions a
left join NEAR.CORE.DIM_TOKEN_LABELS b
on a.token_id = b.token_contract
left join token_prices c
on a.token_id = c.token_contract and TRUNC(a.block_timestamp,'hour') = c.timestamp_h
),
nte_erc20_final as (
select 
distinct sender,
token_id,
symbol,
sum(token_amount) as token_amount,
sum(usd_amt) as usd_amt,
count(distinct tx_hash) as n_transactions
from nte_erc20_totals
group by 1,2,3
),
nte_near_transactions as (
select 
distinct tx_hash,
    deposit/pow(10,24) as amount, 
    'near' as symbol,
    'near' as token_id,
    lower(concat('0x',parse_json(args):eth_recipient::string)) as eth_recipient 
from "NEAR"."CORE"."FACT_ACTIONS_EVENTS_FUNCTION_CALL" 
where method_name = 'migrate_to_ethereum'
  and block_timestamp >= (current_date - 90)
),
nte_near_totals as (
select distinct
a.block_timestamp,
a.tx_hash,
a.tx_signer as sender,
b.amount,
b.symbol,
b.token_id,
b.eth_recipient
from "NEAR"."CORE"."FACT_TRANSACTIONS" a
inner join nte_near_transactions b
on a.tx_hash = b.tx_hash
where a.tx_status = 'Success'
),
nte_near_final as (
select 
distinct sender,
token_id,
symbol,
sum(amount) as token_amount,
sum(amount*price_usd) as usd_amt,
count(distinct tx_hash) as n_transactions
from nte_near_totals a 
left join near_prices b
  on TRUNC(a.block_timestamp,'hour') = b.timestamp_h
group by 1,2,3
),

-- total bridged to eth
bridged_to_eth as (
select * from nte_erc20_final
union 
select * from nte_near_final
),
eth_token_prices as (
	select distinct token_address, 
      symbol,
      decimals,
      TRUNC(hour,'hour') as timestamp_h, 
      avg(price) as price_usd 
  	from ethereum.core.fact_hourly_token_prices
  	where hour >= (current_date - 90)
  	group by 1,2,3,4
),
etn_erc20_total as (
  select block_timestamp, 
    tx_hash, 
    event_inputs:accountId :: string as receiver, 
    event_inputs:sender :: string as sender, 
    event_inputs:token :: string as token_id,
    event_inputs:amount :: number as amount,
    coalesce((event_inputs:amount :: number)/pow(10, b.decimals),amount/pow(10,18)) as token_amount,
    b.symbol,
    token_amount*price_usd as usd_amount
  from ethereum.core.fact_event_logs a
  left join eth_token_prices b
  on a.event_inputs:token :: string = b.token_address and TRUNC(a.block_timestamp,'hour') = b.timestamp_h
  where ORIGIN_TO_ADDRESS = '0x23ddd3e3692d1861ed57ede224608875809e127f' -- Near: Rainbow bridge
  and block_timestamp >= (current_date - 90)
  and CONTRACT_NAME = 'ERC20Locker'
  and EVENT_NAME = 'Locked'
  and receiver like '%.near'
),
etn_erc20_final as (
select 
distinct 
receiver as sender,
token_id,
symbol,
sum(token_amount) as token_amount,
sum(usd_amount) as usd_amount,
count(distinct tx_hash) as n_transactions
from etn_erc20_total 
group by 1,2,3
),
etn_eth_transactions as (
  select 
  block_timestamp,
  tx_hash,
  from_address as eth_address,
  '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2' as token_address,
  'ETH' as symbol,
  'ETH' as token_id,
  eth_value as token_amount,
  substring(input, 1, charindex(lower('2E6E656172'),input)+9) near_namepart1,
  charindex('0000', reverse(near_namepart1)) as z_index,
  substring(near_namepart1,length(near_namepart1)-z_index+2,length(near_namepart1)) as near_namepart,
  substring(near_namepart,2,length(near_namepart)) as near_namepart2,
  trim(coalesce(TRY_HEX_DECODE_STRING(near_namepart :: STRING),TRY_HEX_DECODE_STRING(near_namepart2 :: STRING))) as near_address
  from ethereum.core.fact_traces
  where TO_ADDRESS = lower('0x6BFaD42cFC4EfC96f529D786D643Ff4A8B89FA52')
  and input ilike '%2E6E656172%'
  and block_timestamp >= (current_date - 90)
),
etn_eth_final as (
select 
distinct 
near_address as sender,
token_id,
a.symbol,
sum(token_amount) as token_amount,
sum(token_amount*price_usd) as usd_amount,
count(distinct tx_hash) as n_transactions
from etn_eth_transactions a
left join eth_token_prices b
on a.token_address = b.token_address and TRUNC(a.block_timestamp,'hour') = b.timestamp_h
group by 1,2,3
),


-- total bridged to near
bridged_from_eth as (
select * from etn_eth_final
union 
select * from etn_erc20_final
),


-------------------------------- nft buys and sells 


base_nft_txs as (
select distinct tx_hash from near.core.fact_actions_events_function_call where method_name = 'buy'
  and block_timestamp >= (current_date - 90)
),
base_nft_table as (
select 
  distinct
  block_timestamp,
  tx_hash,
regexp_substr(status_value, 'Success') as reg_success,
  replace(value, 'EVENT_JSON:') as logs_cleaned,
  parse_json(logs_cleaned):params:buyer_id::string as buyer_id,
  parse_json(logs_cleaned):params:owner_id::string as owner_id,  
  parse_json(logs_cleaned):params:nft_contract_id::string as nft_contract_id,
  parse_json(logs_cleaned):params:price::number / pow(10,24) as price
FROM near.core.fact_receipts,
  table(flatten(input =>logs))
WHERE reg_success IS NOT NULL
and tx_hash in (select distinct tx_hash from base_nft_txs)
and receiver_id = 'marketplace.paras.near'
and buyer_id is not null
and owner_id is not null
and parse_json(logs_cleaned):type != 'resolve_purchase_fail'
and block_timestamp >= (current_date - 90)
),
--- nft buys 
buys as (
select distinct 
  buyer_id as trader,
  nft_contract_id,
  count(distinct tx_hash) as n_buys,
  sum(price) as near_amt_buys,
  sum(price * price_usd) as usd_amt_buys
  from base_nft_table a
  left join near_prices b
  on TRUNC(a.block_timestamp,'hour') = b.timestamp_h
  group by 1,2
),
--- nft sells
sells as (
select distinct 
  owner_id as trader,
  nft_contract_id,
  count(distinct tx_hash) as n_sells,
  sum(price) as near_amt_sells,
  sum(price * price_usd) as usd_amt_sells
  from base_nft_table a
  left join near_prices b
  on TRUNC(a.block_timestamp,'hour') = b.timestamp_h
  group by 1,2
),


-------------------------------- dex actions

n_dex_sells as (
  SELECT DISTINCT a.trader, 
  a.platform as protocol,
  a.token_in_contract as token_contract,
  a.token_in as token_symbol,
  count(distinct a.swap_id) as n_sells,
  sum(a.amount_in) as sell_token_volume,
  sum(a.amount_in * b.PRICE_USD) as sell_usd_volume
    FROM near.core.ez_dex_swaps a
  	LEFT JOIN token_prices b 
    on a.token_in_contract = b.token_contract and TRUNC(a.block_timestamp,'hour') = b.timestamp_h
  WHERE a.block_timestamp >= (current_date - 90)
  GROUP BY 1,2,3,4
),

n_dex_buys as (
  SELECT DISTINCT a.trader, 
  a.platform as protocol,
  a.token_out_contract as token_contract,
  a.token_out as token_symbol,
  count(distinct a.swap_id) as n_buys,
  sum(a.amount_out) as buy_token_volume,
  sum(a.amount_out * b.PRICE_USD) as buy_usd_volume
    FROM near.core.ez_dex_swaps a
  	LEFT JOIN token_prices b 
    on a.token_out_contract = b.token_contract and TRUNC(a.block_timestamp,'hour') = b.timestamp_h
  WHERE a.block_timestamp >= (current_date - 90)
  GROUP BY 1,2,3,4
),


-------------------------------- transfers actions


transfers_out as (
    select distinct
    tx_signer as user_address,
  'NEAR' as token_contract,
  'NEAR' as token_symbol,
  count(distinct tx_hash) as n_xfer_out,
  sum(deposit/pow(10,24)) as xfer_out_token_volume,
  sum(deposit/pow(10,24)*price_usd) as xfer_out_usd_volume
  from "NEAR"."CORE"."FACT_TRANSFERS" a
  left join near_prices b
  on TRUNC(a.block_timestamp,'hour') = b.timestamp_h
  where block_timestamp >= (current_date - 90)
  and status = 'TRUE'
  and tx_signer != tx_receiver
  and tx_signer not in (select distinct address from crosschain.core.address_labels where blockchain = 'near')
  group by 1,2,3
),

transfers_in as (
    select distinct
    tx_receiver as user_address,
  'NEAR' as token_contract,
  'NEAR' as token_symbol,
  count(distinct tx_hash) as n_xfer_in,
  sum(deposit/pow(10,24)) as xfer_in_token_volume,
  sum(deposit/pow(10,24)*price_usd) as xfer_in_usd_volume
  from "NEAR"."CORE"."FACT_TRANSFERS" a
  left join near_prices b
  on TRUNC(a.block_timestamp,'hour') = b.timestamp_h
  where block_timestamp >= (current_date - 90)
  and status = 'TRUE'
  and tx_signer != tx_receiver
  and tx_receiver not in (select distinct address from crosschain.core.address_labels where blockchain = 'near')
  group by 1,2,3
),



-------------------------------- put together

total_accumulation_in as (
select sender as user_address,
    token_id as token_contract,
    symbol as token_symbol,
    n_transactions as n_xfer_in,
    token_amount as xfer_in_token_volume,
    usd_amount as xfer_in_usd_volume
from bridged_from_eth
union
select trader as user_address,
    'NEAR' as token_contract,
    'NEAR' as token_symbol,
    n_sells as n_xfer_in,
    near_amt_sells as xfer_in_token_volume,
    usd_amt_sells as xfer_in_usd_volume
from sells
union
select trader as user_address,
    token_contract,
    token_symbol,
    n_buys as n_xfer_in,
    buy_token_volume as xfer_in_token_volume,
    buy_usd_volume as xfer_in_usd_volume
from n_dex_buys
union
select *
from transfers_in
),

total_accumulation_out as (
select sender as user_address,
    token_id as token_contract,
    symbol as token_symbol,
    n_transactions as n_xfer_out,
    token_amount as xfer_out_token_volume,
    usd_amt as xfer_out_usd_volume
from bridged_to_eth
union
select trader as user_address,
    'NEAR' as token_contract,
    'NEAR' as token_symbol,
    n_buys as n_xfer_out,
    near_amt_buys as xfer_out_token_volume,
    usd_amt_buys as xfer_out_usd_volume
from buys
union
select trader as user_address,
    token_contract,
    token_symbol,
    n_sells as n_xfer_out,
    sell_token_volume as xfer_out_token_volume,
    sell_usd_volume as xfer_out_usd_volume
from n_dex_sells
union
select *
from transfers_out

)

SELECT
coalesce(ai.user_address, ao.user_address) AS user_address,
coalesce(ai.token_symbol, ao.token_symbol) AS token_symbol,
coalesce(ai.token_contract, ao.token_contract) AS token_contract,
sum(coalesce(n_xfer_in, 0)) AS n_xfer_in,
sum(coalesce(xfer_in_token_volume, 0)) AS xfer_in_token_volume,
sum(coalesce(xfer_in_usd_volume, 0)) AS xfer_in_usd_volume,
sum(coalesce(n_xfer_out, 0)) AS n_xfer_out,
sum(coalesce(xfer_out_token_volume, 0)) AS xfer_out_token_volume,
sum(coalesce(xfer_out_usd_volume, 0)) AS xfer_out_usd_volume
FROM total_accumulation_in ai
FULL JOIN total_accumulation_out ao 
ON ai.user_address = ao.user_address
AND ai.token_symbol = ao.token_symbol
AND ai.token_contract = ao.token_contract
GROUP BY
1,2,3


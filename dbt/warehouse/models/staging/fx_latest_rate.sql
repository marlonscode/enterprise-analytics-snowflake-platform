{{
    config(
        materialized="table"
    )
}}

select
    base,
    date,
    rates,
    success,
    timestamp
from {{ source('bike_business', 'fx_latest_rate') }}

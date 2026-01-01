{{
    config(
        materialized="table"
    )
}}

select
    {{ dbt_utils.generate_surrogate_key(['address.addressid']) }} as address_key,
    address.addressid as address_id,
    address.addressline1 as street_address,
    address.city,
    sp.name as state_province,
    {{ us_state_to_iso_3166_2('sp.name') }} as state_province_iso_3166_2,
    countryregion.name as country
from {{ ref('ops_address') }} as address
left join {{ ref('ops_stateprovince') }} as sp
    on address.stateprovinceid = sp.stateprovinceid
left join {{ ref('ops_country_region') }} as countryregion
    on sp.countryregioncode = countryregion.countryregioncode
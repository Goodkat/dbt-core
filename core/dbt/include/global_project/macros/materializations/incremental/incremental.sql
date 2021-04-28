
{% materialization incremental, default -%}

  {% set unique_key = config.get('unique_key') %}

  {% set target_relation = this.incorporate(type='table') %}
  {% set existing_relation = load_relation(this) %}
  {% set tmp_relation = make_temp_relation(this) %}

  {% set on_schema_change = incremental_validate_on_schema_change(config.get('on_schema_change')) %}

  {{ run_hooks(pre_hooks, inside_transaction=False) }}

  -- `BEGIN` happens here:
  {{ run_hooks(pre_hooks, inside_transaction=True) }}

  {% do run_query(create_table_as(True, tmp_relation, sql)) %}
  {% set schema_changed = check_for_schema_changes(tmp_relation, target_relation) %}

  {% set trigger_full_refresh = false %}
  {% if should_full_refresh() %}
    {% set trigger_full_refresh = true %}
  {% elif existing_relation.is_view %}
    {% set trigger_full_refresh = true %}
  {% elif schema_changed and on_schema_change == 'full_refresh' %}
    {% set trigger_full_refresh = false %}
  {% endif %}

  {% set to_drop = [] %}
  
  {% if existing_relation is none %}
      {% set build_sql = create_table_as(False, target_relation, sql) %}
  
  {% elif trigger_full_refresh %}
      {#-- Make sure the backup doesn't exist so we don't encounter issues with the rename below #}
      {% set backup_identifier = existing_relation.identifier ~ "__dbt_backup" %}
      {% set backup_relation = existing_relation.incorporate(path={"identifier": backup_identifier}) %}
      {% do adapter.drop_relation(backup_relation) %}

      {% do adapter.rename_relation(target_relation, backup_relation) %}
      {% set build_sql = create_table_as(False, target_relation, sql) %}
      {% do to_drop.append(backup_relation) %}
  
  {% else %}

      {% do process_schema_changes(schema_changed, on_schema_change, tmp_relation, target_relation) %}
      
      {% do adapter.expand_target_column_types(
             from_relation=tmp_relation,
             to_relation=target_relation) %}

      {% set build_sql = incremental_upsert(tmp_relation, target_relation, unique_key=unique_key) %}
  
  {% endif %}

  {% call statement("main") %}
      {{ build_sql }}
  {% endcall %}

  {% do persist_docs(target_relation, model) %}

  {% if existing_relation is none or existing_relation.is_view or should_full_refresh() %}
    {% do create_indexes(target_relation) %}
  {% endif %}

  {{ run_hooks(post_hooks, inside_transaction=True) }}

  -- `COMMIT` happens here
  {% do adapter.commit() %}

  {% for rel in to_drop %}
      {% do adapter.drop_relation(rel) %}
  {% endfor %}

  {{ run_hooks(post_hooks, inside_transaction=False) }}

  {{ return({'relations': [target_relation]}) }}

{%- endmaterialization %}

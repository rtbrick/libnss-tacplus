{
  "table": {
    "table_name": "global.system.software.information",
    "table_type": "system_software_info_table"
  },
  "objects": [
    {
      "attribute": {
        "component": "{{ .project }}",
        "version": "{{ .ver_str }}",
        "branch": "{{ .branch }}",
        "commit": "{{ .git_commit }}",
        "commit_timestamp": {{ .git_commit_ts }},
        "build_timestamp": {{ .build_ts }}
      }
    }
  ]
}

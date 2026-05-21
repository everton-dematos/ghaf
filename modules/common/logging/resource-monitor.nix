# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ pkgs }:
{
  name,
  unit,
  durationSeconds,
  intervalSeconds,
  outputFile,
  completionMessage,
}:

pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = with pkgs; [
    coreutils
    gawk
    systemd
  ];
  text = ''
    unit="${unit}"
    duration="${toString durationSeconds}"
    interval="${toString intervalSeconds}"
    output_file="${outputFile}"

    get_unit_property() {
      local property="$1"

      systemctl show "$unit" --property="$property" --value 2>/dev/null || true
    }

    normalize_counter() {
      local value="$1"

      case "$value" in
        ""|"[not set]"|*[!0-9]*)
          printf '0\n'
          ;;
        *)
          printf '%s\n' "$value"
          ;;
      esac
    }

    bytes_to_mib() {
      local bytes="$1"

      bytes="$(normalize_counter "$bytes")"
      awk -v bytes="$bytes" 'BEGIN { printf "%.2f", bytes / 1048576 }'
    }

    read_cgroup_file() {
      local control_group="$1"
      local filename="$2"
      local cgroup_dir="/sys/fs/cgroup$control_group"

      if [ -n "$control_group" ] && [ -r "$cgroup_dir/$filename" ]; then
        cat "$cgroup_dir/$filename"
      fi

      return 0
    }

    read_memory_counter_bytes() {
      local control_group="$1"
      local filename="$2"
      local fallback="$3"
      local value

      value="$(read_cgroup_file "$control_group" "$filename")"
      if [ -z "$value" ]; then
        value="$fallback"
      fi

      normalize_counter "$value"
    }

    read_cgroup_stat_bytes() {
      local control_group="$1"
      local key="$2"
      local memory_stat="/sys/fs/cgroup$control_group/memory.stat"
      local value=""

      if [ -n "$control_group" ] && [ -r "$memory_stat" ]; then
        value="$(awk -v wanted="$key" '$1 == wanted { printf "%.0f\n", $2; found=1 } END { if (!found) exit 1 }' "$memory_stat" 2>/dev/null || true)"
      fi

      normalize_counter "$value"
    }

    read_proc_status_bytes() {
      local pid="$1"
      local key="$2"
      local status_file="/proc/$pid/status"
      local value=""

      case "$pid" in
        ""|"0"|*[!0-9]*)
          printf '0\n'
          return 0
          ;;
      esac

      if [ -r "$status_file" ]; then
        value="$(awk -v wanted="$key:" '$1 == wanted { printf "%.0f\n", $2 * 1024; found=1 } END { if (!found) exit 1 }' "$status_file" 2>/dev/null || true)"
      fi

      normalize_counter "$value"
    }

    read_proc_smaps_rollup_bytes() {
      local pid="$1"
      local key="$2"
      local smaps_rollup="/proc/$pid/smaps_rollup"
      local value=""

      case "$pid" in
        ""|"0"|*[!0-9]*)
          printf '0\n'
          return 0
          ;;
      esac

      if [ -r "$smaps_rollup" ]; then
        value="$(awk -v wanted="$key:" '$1 == wanted { printf "%.0f\n", $2 * 1024; found=1 } END { if (!found) exit 1 }' "$smaps_rollup" 2>/dev/null || true)"
      fi

      normalize_counter "$value"
    }

    read_cpu_usage_usec() {
      local control_group="$1"
      local fallback_nsec="$2"
      local cpu_stat="/sys/fs/cgroup$control_group/cpu.stat"
      local usage=""

      if [ -n "$control_group" ] && [ -r "$cpu_stat" ]; then
        usage="$(awk '$1 == "usage_usec" { print $2; found=1 } END { if (!found) exit 1 }' "$cpu_stat" 2>/dev/null || true)"
      fi

      if [ -z "$usage" ]; then
        fallback_nsec="$(normalize_counter "$fallback_nsec")"
        usage=$((fallback_nsec / 1000))
      fi

      normalize_counter "$usage"
    }

    mkdir -p "$(dirname "$output_file")"
    printf '%s\n' 'timestamp,elapsed_seconds,unit,active_state,sub_state,main_pid,cgroup_path,memory_current_bytes,memory_current_mib,memory_peak_bytes,memory_peak_mib,memory_swap_current_bytes,memory_swap_current_mib,memory_swap_peak_bytes,memory_swap_peak_mib,cgroup_non_file_bytes,cgroup_non_file_mib,cgroup_anon_bytes,cgroup_anon_mib,cgroup_file_bytes,cgroup_file_mib,cgroup_file_mapped_bytes,cgroup_active_file_bytes,cgroup_inactive_file_bytes,cgroup_kernel_bytes,cgroup_slab_bytes,cgroup_slab_reclaimable_bytes,cgroup_slab_unreclaimable_bytes,process_vmrss_bytes,process_vmrss_mib,process_rss_anon_bytes,process_rss_anon_mib,process_rss_file_bytes,process_rss_shmem_bytes,process_pss_bytes,process_pss_mib,process_pss_anon_bytes,process_pss_file_bytes,process_pss_shmem_bytes,cpu_usage_usec,cpu_delta_usec,cpu_percent' > "$output_file"

    start_ns="$(date +%s%N)"
    end_ns=$((start_ns + duration * 1000000000))
    previous_cpu_usage_usec=""
    previous_sample_ns=""

    while true; do
      now_ns="$(date +%s%N)"
      elapsed_seconds=$(((now_ns - start_ns) / 1000000000))
      timestamp="$(date --iso-8601=seconds)"

      active_state="$(get_unit_property ActiveState)"
      sub_state="$(get_unit_property SubState)"
      main_pid="$(get_unit_property MainPID)"
      control_group="$(get_unit_property ControlGroup)"
      memory_current_prop="$(get_unit_property MemoryCurrent)"
      memory_peak_prop="$(get_unit_property MemoryPeak)"
      memory_swap_current_prop="$(get_unit_property MemorySwapCurrent)"
      memory_swap_peak_prop="$(get_unit_property MemorySwapPeak)"
      cpu_usage_nsec_prop="$(get_unit_property CPUUsageNSec)"

      memory_current_bytes="$(read_memory_counter_bytes "$control_group" "memory.current" "$memory_current_prop")"
      memory_peak_bytes="$(read_memory_counter_bytes "$control_group" "memory.peak" "$memory_peak_prop")"
      memory_swap_current_bytes="$(read_memory_counter_bytes "$control_group" "memory.swap.current" "$memory_swap_current_prop")"
      memory_swap_peak_bytes="$(read_memory_counter_bytes "$control_group" "memory.swap.peak" "$memory_swap_peak_prop")"
      cgroup_anon_bytes="$(read_cgroup_stat_bytes "$control_group" "anon")"
      cgroup_file_bytes="$(read_cgroup_stat_bytes "$control_group" "file")"
      cgroup_file_mapped_bytes="$(read_cgroup_stat_bytes "$control_group" "file_mapped")"
      cgroup_active_file_bytes="$(read_cgroup_stat_bytes "$control_group" "active_file")"
      cgroup_inactive_file_bytes="$(read_cgroup_stat_bytes "$control_group" "inactive_file")"
      cgroup_kernel_bytes="$(read_cgroup_stat_bytes "$control_group" "kernel")"
      cgroup_slab_bytes="$(read_cgroup_stat_bytes "$control_group" "slab")"
      cgroup_slab_reclaimable_bytes="$(read_cgroup_stat_bytes "$control_group" "slab_reclaimable")"
      cgroup_slab_unreclaimable_bytes="$(read_cgroup_stat_bytes "$control_group" "slab_unreclaimable")"

      cgroup_non_file_bytes=$((memory_current_bytes - cgroup_file_bytes))
      if [ "$cgroup_non_file_bytes" -lt 0 ]; then
        cgroup_non_file_bytes=0
      fi

      process_vmrss_bytes="$(read_proc_status_bytes "$main_pid" "VmRSS")"
      process_rss_anon_bytes="$(read_proc_status_bytes "$main_pid" "RssAnon")"
      process_rss_file_bytes="$(read_proc_status_bytes "$main_pid" "RssFile")"
      process_rss_shmem_bytes="$(read_proc_status_bytes "$main_pid" "RssShmem")"
      process_pss_bytes="$(read_proc_smaps_rollup_bytes "$main_pid" "Pss")"
      process_pss_anon_bytes="$(read_proc_smaps_rollup_bytes "$main_pid" "Pss_Anon")"
      process_pss_file_bytes="$(read_proc_smaps_rollup_bytes "$main_pid" "Pss_File")"
      process_pss_shmem_bytes="$(read_proc_smaps_rollup_bytes "$main_pid" "Pss_Shmem")"

      memory_current_mib="$(bytes_to_mib "$memory_current_bytes")"
      memory_peak_mib="$(bytes_to_mib "$memory_peak_bytes")"
      memory_swap_current_mib="$(bytes_to_mib "$memory_swap_current_bytes")"
      memory_swap_peak_mib="$(bytes_to_mib "$memory_swap_peak_bytes")"
      cgroup_non_file_mib="$(bytes_to_mib "$cgroup_non_file_bytes")"
      cgroup_anon_mib="$(bytes_to_mib "$cgroup_anon_bytes")"
      cgroup_file_mib="$(bytes_to_mib "$cgroup_file_bytes")"
      process_vmrss_mib="$(bytes_to_mib "$process_vmrss_bytes")"
      process_rss_anon_mib="$(bytes_to_mib "$process_rss_anon_bytes")"
      process_pss_mib="$(bytes_to_mib "$process_pss_bytes")"

      cpu_usage_usec="$(read_cpu_usage_usec "$control_group" "$cpu_usage_nsec_prop")"

      cpu_delta_usec=0
      cpu_percent="0.00"
      if [ -n "$previous_cpu_usage_usec" ] && [ "$cpu_usage_usec" -ge "$previous_cpu_usage_usec" ] && [ "$now_ns" -gt "$previous_sample_ns" ]; then
        cpu_delta_usec=$((cpu_usage_usec - previous_cpu_usage_usec))
        sample_delta_ns=$((now_ns - previous_sample_ns))
        cpu_percent="$(awk -v cpu_delta_usec="$cpu_delta_usec" -v sample_delta_ns="$sample_delta_ns" \
          'BEGIN { printf "%.2f", (cpu_delta_usec * 100000) / sample_delta_ns }')"
      fi

      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$timestamp" \
        "$elapsed_seconds" \
        "$unit" \
        "$active_state" \
        "$sub_state" \
        "$main_pid" \
        "$control_group" \
        "$memory_current_bytes" \
        "$memory_current_mib" \
        "$memory_peak_bytes" \
        "$memory_peak_mib" \
        "$memory_swap_current_bytes" \
        "$memory_swap_current_mib" \
        "$memory_swap_peak_bytes" \
        "$memory_swap_peak_mib" \
        "$cgroup_non_file_bytes" \
        "$cgroup_non_file_mib" \
        "$cgroup_anon_bytes" \
        "$cgroup_anon_mib" \
        "$cgroup_file_bytes" \
        "$cgroup_file_mib" \
        "$cgroup_file_mapped_bytes" \
        "$cgroup_active_file_bytes" \
        "$cgroup_inactive_file_bytes" \
        "$cgroup_kernel_bytes" \
        "$cgroup_slab_bytes" \
        "$cgroup_slab_reclaimable_bytes" \
        "$cgroup_slab_unreclaimable_bytes" \
        "$process_vmrss_bytes" \
        "$process_vmrss_mib" \
        "$process_rss_anon_bytes" \
        "$process_rss_anon_mib" \
        "$process_rss_file_bytes" \
        "$process_rss_shmem_bytes" \
        "$process_pss_bytes" \
        "$process_pss_mib" \
        "$process_pss_anon_bytes" \
        "$process_pss_file_bytes" \
        "$process_pss_shmem_bytes" \
        "$cpu_usage_usec" \
        "$cpu_delta_usec" \
        "$cpu_percent" >> "$output_file"

      previous_cpu_usage_usec="$cpu_usage_usec"
      previous_sample_ns="$now_ns"

      if [ "$now_ns" -ge "$end_ns" ]; then
        break
      fi

      remaining_ns=$((end_ns - now_ns))
      interval_ns=$((interval * 1000000000))
      sleep_seconds="$interval"

      if [ "$remaining_ns" -lt "$interval_ns" ]; then
        sleep_seconds="$(awk -v remaining_ns="$remaining_ns" 'BEGIN { printf "%.3f", remaining_ns / 1000000000 }')"
      fi

      sleep "$sleep_seconds"
    done

    echo "${completionMessage} $output_file"
  '';
}

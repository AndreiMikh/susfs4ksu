
#!/usr/bin/env bash

set -o pipefail

KERNELMODULE="${KERNELMODULE:-}"
SUBLEVEL="${SUBLEVEL:-0}"
[[ "$SUBLEVEL" =~ ^-?[0-9]+$ ]] || SUBLEVEL=0
MODE="${1:-Apply}"
WORKDIR="${2:-kernel_workspace/kernel_platform/common}"

case "$MODE" in
  Apply|PostFix|Revert) ;;
  *)
    echo "Usage: Bash FakePatches.sh <Apply|PostFix|Revert> [WorkDir]" >&2
    exit 1
    ;;
esac

WORKDIR="${WORKDIR%/}"
[[ -n "$WORKDIR" ]] || WORKDIR="/"

tmpfile=""

cleanup() {
  [[ -n "$tmpfile" && -f "$tmpfile" ]] && rm -f -- "$tmpfile"
}
trap cleanup EXIT

fail() {
  printf '⚠️ Fake Patches Failed: %s\n' "$*" >&2
  exit 1
}

f() {
  printf '%s/%s' "${WORKDIR%/}" "$1"
}

rel() {
  local path="$1"
  printf '%s\n' "${path#"$WORKDIR"/}"
}

log_apply() {
  printf '[APPLY]   %s | %s\n' "$(rel "$1")" "$2"
}

log_postfix() {
  printf '[POSTFIX] %s | %s\n' "$(rel "$1")" "$2"
}

log_revert() {
  printf '[REVERT]  %s | %s\n' "$(rel "$1")" "$2"
}

log_skip() {
  printf '[SKIP]    %s | %s\n' "$(rel "$1")" "$2"
}

require_file() {
  [[ -f "$1" ]] || fail "Required File Does Not Exist: $1"
}

new_tmp() {
  tmpfile="$(mktemp)" || fail "Unable to Create Temporary File"
}

contains() {
  grep -Fq -- "$2" "$1"
}

regex_contains() {
  grep -Eq -- "$2" "$1"
}

# Insert lines after the first matching line.
insert_after_first() {
  local file="$1" anchor="$2"
  shift 2
  local -a newlines=("$@")
  local line present=1

  require_file "$file"

  for line in "${newlines[@]}"; do
    grep -Fxq -- "$line" "$file" || present=0
  done
  (( present )) && return 1

  regex_contains "$file" "$anchor" ||
    fail "Anchor Not Found in $file: $anchor"

  new_tmp
  awk -v anchor="$anchor" '
    !done && $0 ~ anchor {
      print
      while ((getline line < "/dev/stdin") > 0)
        print line
      done=1
      next
    }
    { print }
  ' "$file" </dev/null > "$tmpfile"

  # Rebuild using Bash so the inserted lines are literal.
  : > "$tmpfile"
  local done=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >> "$tmpfile"
    if (( ! done )) && [[ "$line" =~ $anchor ]]; then
      printf '%s\n' "${newlines[@]}" >> "$tmpfile"
      done=1
    fi
  done < "$file"

  (( done )) || fail "Anchor Not Found in $file: $anchor"
  cat "$tmpfile" > "$file" || fail "Unable to Write $file"
  rm -f "$tmpfile"
  tmpfile=""
  return 0
}

# Insert lines before the first matching line.
insert_before_first() {
  local file="$1" anchor="$2"
  shift 2
  local -a newlines=("$@")
  local line present=1 done=0

  require_file "$file"

  for line in "${newlines[@]}"; do
    grep -Fxq -- "$line" "$file" || present=0
  done
  (( present )) && return 1

  new_tmp
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ! done )) && [[ "$line" =~ $anchor ]]; then
      printf '%s\n' "${newlines[@]}" >> "$tmpfile"
      done=1
    fi
    printf '%s\n' "$line" >> "$tmpfile"
  done < "$file"

  (( done )) || fail "Anchor Not Found in $file: $anchor"
  cat "$tmpfile" > "$file" || fail "Unable to Write $file"
  rm -f "$tmpfile"
  tmpfile=""
  return 0
}

# Insert after every matching line, scanning backwards.
insert_after() {
  local file="$1" anchor="$2"
  shift 2
  local -a newlines=("$@")
  local line present=1

  require_file "$file"
  for line in "${newlines[@]}"; do
    grep -Fxq -- "$line" "$file" || present=0
  done
  (( present )) && return 1

  insert_after_first "$file" "$anchor" "${newlines[@]}"
}

delete_line() {
  local file="$1" pattern="$2"
  require_file "$file"

  if ! grep -Eq -- "$pattern" "$file"; then
    return 1
  fi

  new_tmp
  grep -Ev -- "$pattern" "$file" > "$tmpfile" ||
    [[ $? -eq 1 ]] || fail "Unable to Filter $file"
  cat "$tmpfile" > "$file" || fail "Unable to Write $file"
  rm -f "$tmpfile"
  tmpfile=""
  return 0
}

delete_line_and_following() {
  local file="$1" pattern="$2" extra="$3"
  require_file "$file"

  regex_contains "$file" "$pattern" || return 1

  new_tmp
  awk -v pattern="$pattern" -v extra="$extra" '
    skip > 0 { skip--; next }
    $0 ~ pattern { skip=extra; next }
    { print }
  ' "$file" > "$tmpfile" || fail "Unable to Edit $file"

  cat "$tmpfile" > "$file" || fail "Unable to Write $file"
  rm -f "$tmpfile"
  tmpfile=""
  return 0
}

delete_block() {
  local file="$1" start="$2" end="$3"
  require_file "$file"

  new_tmp
  awk -v start="$start" -v end="$end" '
    !inside && $0 ~ start { inside=1; changed=1; next }
    inside {
      if ($0 ~ end) inside=0
      next
    }
    { print }
    END {
      if (inside) exit 2
      if (!changed) exit 3
    }
  ' "$file" > "$tmpfile"
  local status=$?

  if (( status == 2 )); then
    fail "Unterminated Delete Block in $file: $start"
  elif (( status == 3 )); then
    rm -f "$tmpfile"
    tmpfile=""
    return 1
  elif (( status != 0 )); then
    fail "Unable to Delete Block in $file"
  fi

  cat "$tmpfile" > "$file" || fail "Unable to Write $file"
  rm -f "$tmpfile"
  tmpfile=""
  return 0
}

replace_each_line() {
  local file="$1" pattern="$2" replacement="$3"
  require_file "$file"

  if ! grep -Eq -- "$pattern" "$file"; then
    return 1
  fi

  new_tmp
  sed -E "s|$pattern|$replacement|g" "$file" > "$tmpfile" ||
    fail "Unable to Replace Lines in $file"

  cat "$tmpfile" > "$file" || fail "Unable to Write $file"
  rm -f "$tmpfile"
  tmpfile=""
  return 0
}

replace_whole_line() {
  local file="$1" old="$2" new="$3"
  require_file "$file"

  grep -Fxq -- "$old" "$file" || return 1

  new_tmp
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$old" ]]; then
      printf '%s\n' "$new" >> "$tmpfile"
    else
      printf '%s\n' "$line" >> "$tmpfile"
    fi
  done < "$file"

  cat "$tmpfile" > "$file" || fail "Unable to Write $file"
  rm -f "$tmpfile"
  tmpfile=""
  return 0
}

add_inotify_helper() {
  local file="$1"
  if contains "$file" 'inotify_mark_user_mask('; then
    log_skip "$file" "INOTIFY MARK USER MASK() Already Present"
    return
  fi

  insert_before_first "$file" \
    '^static void inotify_fdinfo\(struct seq_file \*m, struct fsnotify_mark \*mark\)$' \
    'static inline u32 inotify_mark_user_mask(struct fsnotify_mark *mark)' \
    '{' \
    $'\treturn mark->mask & IN_ALL_EVENTS;' \
    '}' \
    ''

  log_apply "$file" "Inserted INOTIFY MARK USER MASK() Helper Before INOTIFY FDINFO()"
}

apply_fdinfo() {
  local file="$1"
  require_file "$file"

  if contains "$file" 'inotify_mark_user_mask('; then
    log_skip "$file" "FDINFO Patch Already Applied"
    return
  fi

  contains "$file" 'mask, mark.ignored_mask' ||
    fail "Expected FDInfo Mask Expression Not Found in $file"

  delete_block "$file" '^[[:blank:]]*/\*$' \
    '^[[:blank:]]*u32 mask = mark->mask & IN_ALL_EVENTS;$' ||
    fail "Unable to Remove FDInfo Comment Block in $file"

  log_apply "$file" "Removed Inline Mask-Calculation Comment Block"

  replace_each_line "$file" '\bmask,[[:space:]]*mark\.ignored_mask' \
    'inotify_mark_user_mask(mark)' || true
  log_apply "$file" "Replaced Mask Argument With INOTIFY MARK USER MASK(MARK)"

  replace_each_line "$file" 'ignored_mask:%x' 'ignored_mask:0' || true
  log_apply "$file" "Replaced IGNORED MASK:%X With IGNORED MASK:0"

  add_inotify_helper "$file"
}

revert_fdinfo() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    log_skip "$file" "FDINFO File Does Not Exist"
    return
  fi

  if ! contains "$file" 'inotify_mark_user_mask(' &&
     ! contains "$file" 'ignored_mask:0'; then
    log_skip "$file" "FDINFO Patch Not Present"
    return
  fi

  replace_each_line "$file" 'inotify_mark_user_mask\(mark\)' 'mask' || true
  replace_each_line "$file" 'ignored_mask:0' 'ignored_mask:%x' || true

  delete_block "$file" \
    '^static inline u32 inotify_mark_user_mask\(struct fsnotify_mark \*mark\)$' \
    '^\}$' || true

  log_revert "$file" "Restored Original FDINFO Mask Handling"
}

apply_android15_vma() {
  local task="$1" namespace="$2"
  require_file "$task"
  require_file "$namespace"

  if contains "$task" 'unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;'; then
    log_skip "$task" "Android 15 VMA Patch Already Applied"
    return
  fi

  insert_after_first "$task" \
    'smap_gather_stats\(vma, &mss, last_vma_end\);' \
    'last_vma_end = vma->vm_end;' ||
    fail "Unable to Insert VMA End Assignment"

  log_apply "$task" "Inserted LAST VMA END Update After SMAP GATHER STATS()"

  # Add the conditional braces around the inserted assignment.
  new_tmp
  awk '
    /last_vma_end = vma->vm_end;/ && !done {
      print "\t\t\t\t" $0
      print "\t\t\t}"
      done=1
      next
    }
    {
      if (!done && /if[[:space:]]*\(vma->vm_end > last_vma_end\)/) {
        sub(/[[:space:]]*$/, " {")
      }
      print
    }
  ' "$task" > "$tmpfile" || fail "Unable to Update VMA Conditional"

  cat "$tmpfile" > "$task" || fail "Unable to Write $task"
  rm -f "$tmpfile"
  tmpfile=""

  log_apply "$task" "Wrapped LAST VMA END Update in Conditional Block"

  insert_after_first "$namespace" '#include <trace/hooks/blk\.h>' \
    '#include <trace/hooks/fs.h>' || true
  log_apply "$namespace" "Added TRACE/HOOKS/FS Header Include"

  insert_after_first "$task" 'int ret = 0, copied = 0;' \
    $'\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;' \
    $'\tpagemap_entry_t *res = NULL;'

  log_apply "$task" "Added NR SUBPAGES And PAGEMAP ENTRY T Declarations"
}

revert_android15_vma() {
  local task="$1" namespace="$2"
  [[ -f "$task" && -f "$namespace" ]] || return

  delete_line "$namespace" '^#include <trace/hooks/fs\.h>$' || true
  delete_line "$task" '^[[:space:]]*unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;$' || true
  delete_line "$task" '^[[:space:]]*pagemap_entry_t \*res = NULL;$' || true
  delete_line "$task" '^[[:space:]]*last_vma_end = vma->vm_end;$' || true

  replace_each_line "$task" \
    'if[[:space:]]*\(vma->vm_end > last_vma_end\)[[:space:]]*\{$' \
    'if (vma->vm_end > last_vma_end)' || true

  # Remove the brace introduced by the patch.
  new_tmp
  awk '
    !removed && $0 == "\t\t\t}" { removed=1; next }
    { print }
  ' "$task" > "$tmpfile"
  cat "$tmpfile" > "$task"
  rm -f "$tmpfile"
  tmpfile=""

  log_revert "$task" "Restored Original Android 15 VMA Block"
  log_revert "$namespace" "Removed TRACE/HOOKS/FS.H Include"
}

postfix() {
  local task namei openC header lastInclude

  task="$(f fs/proc/task_mmu.c)"

  if [[ -f "$task" ]]; then
    if contains "$task" 'VMA_PAD_START(' &&
       ! regex_contains "$task" '#include <linux/pgsize_migration(_inline)?\.h>' &&
       ! regex_contains "$task" '^[[:space:]]*#define[[:space:]]+VMA_PAD_START'; then
      new_tmp
      {
        printf '%s\n' '#ifndef VMA_PAD_START'
        printf '%s\n' '#define VMA_PAD_START(vma) ((vma)->vm_end)'
        printf '%s\n' '#endif'
        cat "$task"
      } > "$tmpfile"
      cat "$tmpfile" > "$task"
      rm -f "$tmpfile"
      tmpfile=""
      log_postfix "$task" "Inserted VMA PAD START() Fallback"
    fi

    if contains "$task" '__fold_filemap_fixup_entry(' &&
       ! regex_contains "$task" 'static[[:space:]]+inline[[:space:]]+void[[:space:]]+__fold_filemap_fixup_entry'; then
      header="$(f include/linux/page_size_compat.h)"

      if [[ -f "$header" ]] && contains "$header" '__fold_filemap_fixup_entry'; then
        if ! contains "$task" '#include <linux/page_size_compat.h>'; then
          insert_after_first "$task" '^#include ' \
            '#include <linux/page_size_compat.h>'
          log_postfix "$task" "Added PAGE_SIZE_COMPAT.H Include"
        fi
      else
        new_tmp
        awk '
          { lines[NR]=$0 }
          END {
            last=0
            for (i=1; i<=NR; i++)
              if (lines[i] ~ /^[[:space:]]*#include/) last=i
            for (i=1; i<=NR; i++) {
              print lines[i]
              if (i==last) {
                print "#ifndef __fold_filemap_fixup_entry"
                print "static inline void __fold_filemap_fixup_entry(struct vma_iterator *iter, unsigned long *end) { }"
                print "#endif /* __fold_filemap_fixup_entry */"
              }
            }
          }
        ' "$task" > "$tmpfile"
        cat "$tmpfile" > "$task"
        rm -f "$tmpfile"
        tmpfile=""
        log_postfix "$task" "Inserted No-OP FOLD FILEMAP FIXUP ENTRY() Stub"
      fi
    fi
  fi

  if [[ "$KERNELMODULE" == android12-5.10 || "$KERNELMODULE" == android13-5.10 ]]; then
    namei="$(f fs/namei.c)"
    if [[ -f "$namei" ]] && contains "$namei" 'set_nameidata(nd, old_dfd, fake_filename, NULL)'; then
      replace_each_line "$namei" \
        'set_nameidata\(nd, old_dfd, fake_filename, NULL\)' \
        'set_nameidata(nd, old_dfd, fake_filename)'
      log_postfix "$namei" "Rewrote 4-Arg SET NAMEIDATA() to 3-Arg Form"
    fi
  fi

  if [[ "$KERNELMODULE" == android16-6.12 ]]; then
    openC="$(f fs/open.c)"
    if [[ -f "$openC" ]] && contains "$openC" 'getname_flags(filename, lookup_flags, NULL)'; then
      replace_each_line "$openC" \
        'getname_flags\(filename, lookup_flags, NULL\)' \
        'getname_flags(filename, lookup_flags)'
      log_postfix "$openC" "Rewrote 3-Arg GETNAME FLAGS() to 2-Arg Form"
    fi
  fi
}

apply() {
  local file base namespace openC memory superC task exec susfs

  case "$KERNELMODULE" in
    android12-5.10)
      if (( SUBLEVEL <= 43 )); then
        file="$(f fs/proc/base.c)"
        replace_each_line "$file" \
          '(int|size_t)[[:space:]]+this_len[[:space:]]*=[[:space:]]*min_t[[:space:]]*\([[:space:]]*\1[[:space:]]*,' \
          'size_t this_len = min_t(size_t,' || true
        log_apply "$file" "Normalized THIS LEN/MIN T() to SIZE T"
      fi
      if (( SUBLEVEL <= 117 )); then apply_fdinfo "$(f fs/notify/fdinfo.c)"; fi
      ;;

    android13-5.10)
      if (( SUBLEVEL <= 107 )); then apply_fdinfo "$(f fs/notify/fdinfo.c)"; fi
      ;;

    android13-5.15)
      if (( SUBLEVEL <= 41 )); then
        namespace="$(f fs/namespace.c)"
        insert_after_first "$namespace" '^#include <linux/shmem_fs\.h>$' \
          '#include <linux/mnt_idmapping.h>' || true
        log_apply "$namespace" "Added LINUX/MNT IDMAPPING Header Include"

        openC="$(f fs/open.c)"
        insert_after_first "$openC" '^#include <linux/compat\.h>$' \
          '#include <linux/mnt_idmapping.h>' || true
        log_apply "$openC" "Added LINUX/MNT IDMAPPING Header Include"

        apply_fdinfo "$(f fs/notify/fdinfo.c)"
      fi

      if (( SUBLEVEL >= 123 )); then
        memory="$(f mm/memory.c)"
        if delete_line "$memory" '#include <linux/swap_slots\.h>'; then
          log_apply "$memory" "Removed LINUX/SWAP SLOTS Header"
        fi
      fi

      if (( SUBLEVEL >= 197 )); then
        namespace="$(f fs/namespace.c)"
        if delete_line "$namespace" '^#include <trace/hooks/blk\.h>$'; then
          log_apply "$namespace" "Removed TRACE/HOOKS/BLK Header"
        fi
      fi

      if (( SUBLEVEL >= 206 )); then
        task="$(f fs/proc/task_mmu.c)"
        if delete_line "$task" '^#include <trace/hooks/mm\.h>$'; then
          log_apply "$task" "Removed TRACE/HOOKS/MM Header"
        fi
      fi
      ;;

    android14-6.1)
      if (( SUBLEVEL <= 25 )); then
        base="$(f fs/proc/base.c)"
        insert_after_first "$base" '^#include <trace/events/oom\.h>$' \
          '#include <trace/hooks/sched.h>' || true
        log_apply "$base" "Added TRACE/HOOKS/SCHED Header"
      fi

      if (( SUBLEVEL <= 141 )); then
        base="$(f fs/proc/base.c)"
        insert_after_first "$base" '^#include <linux/cpufreq_times\.h>$' \
          '#include <linux/dma-buf.h>' || true
        log_apply "$base" "Added LINUX/DMA-BUF Header"
      fi

      if (( SUBLEVEL >= 157 )); then
        namespace="$(f fs/namespace.c)"
        if delete_line "$namespace" '^#include <trace/hooks/blk\.h>$'; then
          log_apply "$namespace" "Removed TRACE/HOOKS/BLK Header"
        fi

        superC="$(f fs/super.c)"
        if delete_line_and_following "$superC" '^#include <trace/hooks/fs\.h>$' 1; then
          log_apply "$superC" "Removed TRACE/HOOKS/FS Header and Following Line"
        fi
      fi
      ;;

    android15-6.6)
      if (( SUBLEVEL <= 30 )); then
        apply_android15_vma "$(f fs/proc/task_mmu.c)" "$(f fs/namespace.c)"
      fi

      if (( SUBLEVEL <= 57 )); then
        memory="$(f mm/memory.c)"
        insert_after_first "$memory" '^#include <linux/sched/sysctl\.h>$' \
          '#include <linux/zswap.h>' || true
        log_apply "$memory" "Added LINUX/ZSWAP Header"
      fi

      if (( SUBLEVEL <= 92 )); then
        base="$(f fs/proc/base.c)"
        insert_after_first "$base" '^#include <linux/cpufreq_times\.h>$' \
          '#include <linux/dma-buf.h>' || true
        log_apply "$base" "Added LINUX/DMA-BUF Header"
      fi
      ;;

    android16-6.12)
      if (( SUBLEVEL >= 58 )); then
        exec="$(f fs/exec.c)"
        if delete_line "$exec" '^#include <linux/dma-buf\.h>$'; then
          log_apply "$exec" "Removed LINUX/DMA-BUF Header"
        fi
      fi
      ;;
  esac
}

revert() {
  local file namespace openC susfs memory task base superC exec

  case "$KERNELMODULE" in
    android12-5.10)
      if (( SUBLEVEL <= 43 )); then
        file="$(f fs/proc/base.c)"
        if replace_whole_line "$file" \
          'size_t this_len = min_t(size_t, count, PAGE_SIZE);' \
          'int this_len = min_t(int, count, PAGE_SIZE);'; then
          log_revert "$file" "Restored INT THIS LEN/MIN T(INT)"
        fi
      fi
      if (( SUBLEVEL <= 117 )); then revert_fdinfo "$(f fs/notify/fdinfo.c)"; fi
      ;;

    android13-5.10)
      if (( SUBLEVEL <= 107 )); then revert_fdinfo "$(f fs/notify/fdinfo.c)"; fi
      ;;

    android13-5.15)
      if (( SUBLEVEL <= 41 )); then
        namespace="$(f fs/namespace.c)"
        delete_line "$namespace" '^#include <linux/mnt_idmapping\.h>$' || true
        log_revert "$namespace" "Removed LINUX/MNT IDMAPPING Header"

        openC="$(f fs/open.c)"
        delete_line "$openC" '^#include <linux/mnt_idmapping\.h>$' || true
        log_revert "$openC" "Removed LINUX/MNT IDMAPPING Header"

        susfs="$(f fs/susfs.c)"
        if [[ -f "$susfs" ]]; then
          replace_each_line "$susfs" \
            'i_uid_into_mnt\(i_user_ns\(&fi->inode\), &fi->inode\)\.val' \
            'i_uid_into_mnt(&init_user_ns, &fi->inode).val' || true
          replace_each_line "$susfs" \
            'i_uid_into_mnt\(i_user_ns\(inode\), inode\)\.val' \
            'i_uid_into_mnt(&init_user_ns, inode).val' || true
          log_revert "$susfs" "Restored SUSFS IUID INTO MNT() Form"
        fi

        revert_fdinfo "$(f fs/notify/fdinfo.c)"
      fi

      if (( SUBLEVEL >= 123 )); then
        memory="$(f mm/memory.c)"
        if ! contains "$memory" '#include <linux/swap_slots.h>'; then
          insert_before_first "$memory" '^#ifdef CONFIG_KSU_KSUFS_SUS_MAP$' \
            '#include <linux/swap_slots.h>'
          log_revert "$memory" "Restored LINUX/SWAP SLOTS Header"
        fi
      fi

      if (( SUBLEVEL >= 197 )); then
        namespace="$(f fs/namespace.c)"
        if ! contains "$namespace" '#include <trace/hooks/blk.h>'; then
          insert_after_first "$namespace" '^#include "internal\.h"$' \
            '#include <trace/hooks/blk.h>'
          log_revert "$namespace" "Restored TRACE/HOOKS/BLK Header"
        fi
      fi

      if (( SUBLEVEL >= 206 )); then
        task="$(f fs/proc/task_mmu.c)"
        if ! contains "$task" '#include <trace/hooks/mm.h>'; then
          insert_after_first "$task" '^#include <linux/pkeys\.h>$' \
            '#include <trace/hooks/mm.h>'
          log_revert "$task" "Restored TRACE/HOOKS/MM Header"
        fi
      fi
      ;;

    android14-6.1)
      if (( SUBLEVEL <= 25 )); then
        base="$(f fs/proc/base.c)"
        delete_line "$base" '^#include <trace/hooks/sched\.h>$' || true
        log_revert "$base" "Removed TRACE/HOOKS/SCHED Header"
      fi

      if (( SUBLEVEL <= 141 )); then
        base="$(f fs/proc/base.c)"
        delete_line "$base" '^#include <linux/dma-buf\.h>$' || true
        log_revert "$base" "Removed LINUX/DMA-BUF Header"
      fi

      if (( SUBLEVEL >= 157 )); then
        namespace="$(f fs/namespace.c)"
        if ! contains "$namespace" '#include <trace/hooks/blk.h>'; then
          insert_after_first "$namespace" '^#include "internal\.h"$' \
            '#include <trace/hooks/blk.h>'
        fi

        superC="$(f fs/super.c)"
        if ! contains "$superC" '#include <trace/hooks/fs.h>'; then
          insert_after_first "$superC" '^#include "internal\.h"$' \
            '#include <trace/hooks/fs.h>'
        fi

        log_revert "$namespace" "Restored TRACE/HOOKS/BLK Header"
        log_revert "$superC" "Restored TRACE/HOOKS/FS Header"
      fi
      ;;

    android15-6.6)
      if (( SUBLEVEL <= 30 )); then
        revert_android15_vma "$(f fs/proc/task_mmu.c)" "$(f fs/namespace.c)"
      fi

      if (( SUBLEVEL <= 57 )); then
        memory="$(f mm/memory.c)"
        delete_line "$memory" '^#include <linux/zswap\.h>$' || true
        log_revert "$memory" "Removed LINUX/ZSWAP Header"
      fi

      if (( SUBLEVEL <= 92 )); then
        base="$(f fs/proc/base.c)"
        delete_line "$base" '^#include <linux/dma-buf\.h>$' || true
        log_revert "$base" "Removed LINUX/DMA-BUF Header"
      fi
      ;;

    android16-6.12)
      if (( SUBLEVEL >= 58 )); then
        exec="$(f fs/exec.c)"
        if ! contains "$exec" '#include <linux/dma-buf.h>'; then
          insert_after_first "$exec" '^#include ' \
            '#include <linux/dma-buf.h>'
          log_revert "$exec" "Restored LINUX/DMA-BUF Header"
        fi
      fi
      ;;
  esac
}

case "$MODE" in
  Apply)
    apply
    ;;
  PostFix)
    postfix
    ;;
  Revert)
    revert
    ;;
esac

printf '🚀 Fake Patches: %s Completed (Kernel Module=%s, Sub Level=%s)\n' \
  "$MODE" "$KERNELMODULE" "$SUBLEVEL"

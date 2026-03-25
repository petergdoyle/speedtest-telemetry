#!/usr/bin/env python3
import csv
import argparse
import sys
from zoneinfo import ZoneInfo
from datetime import datetime
import os
import shutil

def adjust_timezone(file_path, from_tz_str, to_tz_str, dry_run=False, backup=True, smart=False):
    try:
        from_tz = ZoneInfo(from_tz_str)
        to_tz = ZoneInfo(to_tz_str)
    except Exception as e:
        print(f"Error: Invalid timezone: {e}")
        sys.exit(1)

    if not os.path.exists(file_path):
        print(f"Error: File not found: {file_path}")
        return

    print(f"Processing {file_path}...")
    
    rows = []
    header = []
    try:
        with open(file_path, 'r', newline='') as f:
            reader = csv.DictReader(f)
            header = reader.fieldnames
            if not header or 'timestamp' not in header:
                print(f"Error: 'timestamp' column not found in {file_path}")
                return
            for row in reader:
                rows.append(row)
    except Exception as e:
        print(f"Error reading {file_path}: {e}")
        return

    if not rows:
        print(f"  File {file_path} is empty or contains only header. Skipping.")
        return

    def convert_ts(ts_str):
        if not ts_str:
            return ts_str
        try:
            # Parse assuming format YYYY-MM-DD HH:MM:SS
            dt = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S")
            
            # Smart check: if target-tz is Denver and entry is in the future (~6h ahead)
            # then it's definitely UTC.
            if smart:
                now_to = datetime.now(to_tz).replace(tzinfo=None)
                # If entry is more than 30 mins ahead of "now" in target timezone,
                # we assume it's UTC and needs adjustment.
                if dt <= now_to:
                    return ts_str

            # Localize to from_tz (assuming it's naive and representing from_tz)
            dt = dt.replace(tzinfo=from_tz)
            # Convert to to_tz
            dt_new = dt.astimezone(to_tz)
            return dt_new.strftime("%Y-%m-%d %H:%M:%S")
        except Exception:
            return ts_str

    modified = False
    for row in rows:
        old_ts = row['timestamp']
        new_ts = convert_ts(old_ts)
        if old_ts != new_ts:
            row['timestamp'] = new_ts
            modified = True
    
    if not modified:
        print("  No changes needed or timestamps already match target.")
        return

    sample_old = rows[0]['timestamp'] if rows else "N/A"
    print(f"  Adjustment active. Example: {rows[0]['timestamp']}")

    if dry_run:
        print(f"  [DRY RUN] Would write {len(rows)} rows to {file_path}")
    else:
        if backup:
            backup_path = file_path + ".bak"
            shutil.copy2(file_path, backup_path)
            print(f"  Backup created: {backup_path}")
        
        try:
            with open(file_path, 'w', newline='') as f:
                # header is guaranteed to be a list of strings by the check above
                field_names = [str(h) for h in header] if header else []
                writer = csv.DictWriter(f, fieldnames=field_names)
                writer.writeheader()
                writer.writerows(rows)
            print(f"  Successfully updated {file_path}")
        except Exception as e:
            print(f"  Error writing to {file_path}: {e}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Adjust timezone of speedtest CSV logs.")
    parser.add_argument("files", nargs="+", help="CSV files to process")
    parser.add_argument("--from-tz", default="UTC", help="Source timezone (default: UTC)")
    parser.add_argument("--to-tz", default="America/Denver", help="Target timezone (default: America/Denver)")
    parser.add_argument("--dry-run", action="store_true", help="Do not write changes")
    parser.add_argument("--no-backup", action="store_false", dest="backup", help="Do not create backup files")
    parser.add_argument("--smart", action="store_true", help="Only convert entries that appear to be in the future (UTC entries in a local-time file)")
    
    args = parser.parse_args()
    
    for f in args.files:
        adjust_timezone(f, args.from_tz, args.to_tz, args.dry_run, args.backup, args.smart)

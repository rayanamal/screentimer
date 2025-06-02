#!/usr/bin/env nu



# The workflow:
# 
# 1. We start off at offline mode. We are constantly trying to get clock data from google.com
#   The only check that is run is the offline time check.
#   The reason is system clock can not be trusted, as it can be altered by the user through the OS or BIOS.
# 
# 2. Once we get the clock data from google.com, we are in the online mode, where all other checks happen.

let data_dir: path = '/var/lib/screentimer/' | path expand
let config_file: path = '/etc/screentimer/config.toml' | path expand

let optionals = {
    allowed_times: null,
    extra_time: null,
    total_time: null,
    offline_time: null,
}

if not ($config_file | path exists) {
    print -e $"Error: No configuration file found at path ($config_file)"
    exit 1
}

let config = (
    $optionals 
    | merge (open $config_file)
    | update allowed_times {if $in != null {parse-allowlist}}
)

mkdir $data_dir
let db_file: path = ($data_dir | path join 'db.sqlite')

# SQLite database initialization
let conversions_from_db = {
    spent_offline: {into duration}
    spent_extra: {into duration}
    spent_total: {into duration}
    last_reset: {into datetime}
}

if ($db_file | path exists) {
    stor import --file-name $db_file
} else {
    stor create -t db -c {spent_extra: int, spent_total: int, spent_offline: int, last_reset: int}
    stor insert -t db -d {spent_extra: 0, spent_total: 0, spent_offline: 0, last_reset: ($config.day_start | into datetime)}
	stor export --file-name $db_file
}

def get-var [name: string]: nothing -> any {
    stor open
    | query db $"select ($name) from db"
    | get 0
    | get $name
    | do ($conversions_from_db | get $name)
}

def set-var [name: string, value: any]: nothing -> nothing {
    stor update -t db -u {$name: ($value | into int)}
    ignore
}

alias save-to-disk = stor export --file-name $db_file

def main []: nothing -> nothing {
    mut now_minus_uptime: datetime = (0 | into datetime);
    
    # All screen time restriction checks are defined here.
    # Checks with higher priority override the result of checks with lower priority.
    # The results of checks with the same priority are OR'ed. This means if any one check results in block decision, the system is blocked.
    let checks: table<id: string, priority: int, condition: closure block: closure, increment: closure, db-key: string> = [
        {
            id: 'offline-time',
            priority: 3
            condition: {||}
            block: {||}
            db-key: 'spent_offline'
            increment: {||}
        }
        {
            id: 'allowed-time'
            priority: 1
            condition: {||}
            block: {||}
        }
        {
            id: 'total-time'
            priority: 1
            condition: {||}
            block: {||}
            increment: {||}
            db-key: 'spent_total'
        }
        {
            id: 'extra-time'
            priority: 2
            condition: {||}
            block: {||}
            increment: {||}
            db-key: 'spent_extra'
        }
    ]
    
    loop {
        let now = (try {
            http head https://google.com  
            | transpose -rd
            | get date
            | into datetime
        })
        
        if $now != null {
            $now_minus_uptime = $now - (sys host).uptime
            break
        } else if $now == null {
            if $config.offline_time == true {
                set-var spent_offline ((get-var spent_offline) + 1min)
                if (get-var spent_offline) > $config.offline_time { block }
            } else if $config.offline_time == false { block }
        }
        save-to-disk
        sleep 1min
    }
    
    # TODO how do we account for timezone?
    # TODO the issue of needing to reboot times unopened days should be resolved.
    # TODO notify should work, use libnotify (notify-send)
    # TODO move on from using db to variable in the 20sec loop. only the save-to-disk loop should be concerned with db at all.
    
    # Save the database to disk every minute.
    job spawn { loop {
        save-to-disk
        sleep 1min
    }}
    
    # The loop that runs every 20 seconds, for the rest of the stuff.
    loop {
        checks | each {|check|
            if ($check.db-key? != null) {
                if (do $check.increment) {
                    set-var $check.db-key ((get-var $check.db-key) + 1)
                }
            }
        }
        sleep 20sec
    }
    
    ignore
}

# def main []: nothing -> nothing {
# 	# alias notify = notify-send -a "screentime-nixos" -s "1 minute left to termination" -t "Your user session will be terminated in 60 seconds." --timeout 60sec
# 	# notify

# 	let allowed_times = $config.allowed_times | parse-allowlist
# 	let last_reset = (v last_reset | into datetime)
# 	mut next_reset = $last_reset + 1day

# 	loop {
# 		let online: bool = (
# 			ping -c 5 8.8.8.8
# 			| complete
# 			| $in.exit_code == 0
# 		)
# 		if $online {
# 			if not (is-time-allowed "now" $allowed_times) {
# 				set extra ((v extra) + 1min)	
# 				if (v extra) == 1min or (v extra) > $EXTRA_MINS {
# 					block
# 				} else if (v extra) == $EXTRA_MINS {
# 					# notify
# 				}
# 			}
# 			if (date now) > $next_reset {
# 				set last_reset ($next_reset | into int)
# 				$next_reset = $next_reset + 1day
# 				set extra 0min
# 				set offline 0min
# 			}
# 		} else if not $online {
# 			set offline ((v offline) + 1min)
# 			if (v offline) > $MAX_OFFLINE {
# 				# if (v offline_block_counter) >= 3 {
# 				# 	set offline_block_counter 0
# 					block
# 				# } else {
# 				# 	set offline_block_counter ((v offline_block_counter) + 1)
# 				# }
# 			} else if (v offline) == $MAX_OFFLINE {
# 				# notify
# 			}
# 		}
# 		sleep (1min - (4sec + 40ms)) # every interval between pings take 1.01 seconds and we ping 5 times.
# 		# sleep 100ms # for testing
# 	}
# }

def "main list-timezones" []: nothing -> table<timezone: string> {
	date list-timezone
}

def block []: nothing -> nothing {
	# print "User is blocked." ; exit # for testing
	if (sys host).uptime >= $config.after_boot_allowed {
		$config.users  | each {
			let user: string = $in
			print $"User \"($user)\" is terminated."
			try { loginctl kill-user $user }
		}
	}
}

# Convert a 24-hour clock string to a duration value
def clock-to-duration []: string -> duration {
	str trim
	| str replace -a ':' '.'
	| parse-expect '(?<hours>\d{1,2}).(?<minutes>\d{2})'
	| into record
	| $"($in.hours)hr ($in.minutes)min"
	| into duration
}

# Parse a string using a regex and exit with an error message if there are no matches
def parse-expect [regex]: string -> list<any> {
	parse -r $regex
    | if ($in | is-empty) {
        print -e $'Provided input string "($in)" is in an invalid format. It should conform to the regular expression "($regex)"' 
        exit 1
    } else { }
}

# Parse a list of time range strings into a table
def parse-allowlist []: list<string> -> table<start: duration, end: duration> {
	each {|str|
		str trim
		| parse-expect '(?<start>\S+)\s*-\s*(?<end>\S+)'
		| update cells {
			clock-to-duration
		}
		| into record
		| if ($in.start > $in.end) {
			print -e $"Start time ($in.start) is after end time ($in.end) in the provided input string: ($str)"
			exit 1
		} else {}
	}
}

# Check whether the given hour is in the allowed times
def is-time-allowed [test_hour: string, allowlist: table<start: duration, end: duration>]: nothing -> bool {
	let hour = (
		if $test_hour == 'now' {
			date now
			| format date "%H.%M"
		} else {
			$test_hour
		}
		| clock-to-duration
	)
	$allowlist
	| any {|it|
		$hour >= $it.start and $hour <= $it.end
	}
}

# A function to test time allowlist parsing
export def test [] {
	open ./tests.nuon
	| enumerate
	| each {|e|
		let test = $e.item
		let ind = $e.index | $" ($in):" | fill -w 4
		let allowed_hours = $test.allowlist | parse-allowlist
		let result = is-time-allowed $test.hour $allowed_hours
		if $result != $test.expected {
			print $"\n($ind) FAIL: expected ($test.expected) but got ($result)\n"
			print $"\nTested ($test.hour) against ($test.allowlist)"
		} else {
			print $"($ind) PASS: expected ($test.expected) and got ($result)"
		}
	}
	ignore
}
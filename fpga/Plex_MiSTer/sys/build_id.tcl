
# Build TimeStamp Verilog Module
# Jeff Wiencrot - 8/1/2011
# Sorgelig - 02/11/2019
# Reads DATE/GIT/SRC written by scripts/gen_build_stamp.py. The remote fit
# rsyncs only this project directory into a container, so `git` here sees no
# repository and would stamp every build "nogit"; the stamp is generated on the
# host, where the repository is visible, and travels with the project.
proc readBuildStamp {} {
	set stamp [dict create]
	set stampFile "build_id_stamp.txt"
	if {![file exists $stampFile]} {
		return $stamp
	}
	set fh [open $stampFile "r"]
	set text [read $fh]
	close $fh
	foreach line [split $text "\n"] {
		set line [string trim $line]
		if {$line eq "" || [string index $line 0] eq "#"} { continue }
		set eq [string first "=" $line]
		if {$eq < 1} { continue }
		dict set stamp [string range $line 0 [expr {$eq - 1}]] \
			[string range $line [expr {$eq + 1}] end]
	}
	return $stamp
}

proc generateBuildID_Verilog {} {

	# Get the timestamp (see: http://www.altera.com/support/examples/tcl/tcl-date-time-stamp.html)
	set dateString [clock format [ clock seconds ] -format %y%m%d]
	set gitString "nogit"
	if {![catch {exec git rev-parse --short=8 HEAD} gitOut]} {
		set gitString [string trim $gitOut]
		if {![catch {exec git diff --quiet --ignore-submodules HEAD --}]} {
			# clean tree
		} else {
			append gitString "D"
		}
	}
	set idString "$dateString-$gitString"

	# The host-generated stamp wins when present: it carries the real git
	# identity plus SRC, a digest of the fit inputs. SRC is what makes the id
	# honest — it changes whenever the fitted sources change, even if the git
	# identity is missing, stale, or reused.
	set stamp [readBuildStamp]
	if {[dict exists $stamp BUILD_ID] && [dict get $stamp BUILD_ID] ne ""} {
		set idString [dict get $stamp BUILD_ID]
		if {[dict exists $stamp DATE] && [dict get $stamp DATE] ne ""} {
			set dateString [dict get $stamp DATE]
		}
		post_message "Build stamp: build_id_stamp.txt -> $idString"
	} else {
		post_message -type warning \
			"No build_id_stamp.txt: BUILD_ID falls back to \"$idString\"; run scripts/gen_build_stamp.py before the fit for a source-derived identity."
	}

	set buildData "`define BUILD_DATE \"$dateString\"\n`define BUILD_ID \"$idString\""

	# Create a Verilog file for output
	set outputFileName "build_id.v"
	
	set fileData ""
	if { [file exists $outputFileName]} {
		set outputFile [open $outputFileName "r"]
		set fileData [read $outputFile]
		close $outputFile	
	}

	if {$buildData ne $fileData} {
		set outputFile [open $outputFileName "w"]
		puts -nonewline $outputFile $buildData
		close $outputFile
		# Send confirmation message to the Messages window
		post_message "Generated: [pwd]/$outputFileName: $buildData"
	}
}

# Build CDF file
# Sorgelig - 17/2/2018
proc generateCDF {revision device outpath} {

	set outputFileName "jtag.cdf"
	set outputFile [open $outputFileName "w"]

	puts $outputFile "JedecChain;"
	puts $outputFile "	FileRevision(JESD32A);"
	puts $outputFile "	DefaultMfr(6E);"
	puts $outputFile ""
	puts $outputFile "	P ActionCode(Ign)"
	puts $outputFile "		Device PartName(SOCVHPS) MfrSpec(OpMask(0));"
	puts $outputFile "	P ActionCode(Cfg)"
	puts $outputFile "		Device PartName($device) Path(\"$outpath/\") File(\"$revision.sof\") MfrSpec(OpMask(1));"
	puts $outputFile "ChainEnd;"
	puts $outputFile ""
	puts $outputFile "AlteraBegin;"
	puts $outputFile "	ChainType(JTAG);"
	puts $outputFile "AlteraEnd;"
}

set project_name [lindex $quartus(args) 1]
set revision [lindex $quartus(args) 2]

if {[project_exists $project_name]} {
    if {[string equal "" $revision]} {
        project_open $project_name -revision [get_current_revision $project_name]
    } else {
        project_open $project_name -revision $revision
    }
} else {
    post_message -type error "Project $project_name does not exist"
    exit
}

set device  [get_global_assignment -name DEVICE]
set outpath [get_global_assignment -name PROJECT_OUTPUT_DIRECTORY]

if [is_project_open] {
    project_close
}

generateBuildID_Verilog
generateCDF $revision $device $outpath

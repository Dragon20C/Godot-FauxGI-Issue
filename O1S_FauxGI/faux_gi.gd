@tool
extends Node3D
##	Faux Global Illumination
##[br][br]
##	O1S Gaming
##	Jonathan Dummer
##	(MIT License)
##
##	Using the existing lights and collision geometry, approximate GI by placing
##	Virtual Point Lights (VPL) as appropriate.  A primary goal is running on even the
##	Compatibilty renderer, so design around those limits.  (Each mesh can light
##	up to 8 Omnis + 8 Spots, with a max of 32 lights active in view.)  Don't use
##	shadows on the VPLs.
##
##	Minimal implementation, for each original...
##		SpotLight3D: itself, 1+ VPL
##		OmniLight3D: itself, 1+ VPL
##		DirectionalLight3D: itself, 1+ VPL
##
##	While the number of VPLs is limited, we can place and power them using an
##	average of multiple raycast samples, so the final results are representative
##	of more than a single sample.
##
##	Notes:
##		* we can approx an omni with a spot @ 180 deg
##			- this wouldn't work with shadows (~70 deg looks OK), but...
##			- so a mesh can have 16 VPLs
##			- still a dark spot, normal matters
##
##	for evenly distributing points in a 2D field see:
##		https://extremelearning.com.au/unreasonable-effectiveness-of-quasirandom-sequences/
##	and for going from 2D to 3D normal vectors see:
##		Vector3.octahedron_decode( uv: Vector2 )

## VPLs use omni *AND* spot (180 deg), Compatibility's per-mesh limit is "8 spot + 8 omni"
const VPLs_use_spots : bool = true
## Do we want to spawn VPLs for source lights which don't cast shadows?
const include_shadowless : bool = true
## Do we want to hotkey GTRL+G to toggle FauxGI?
const enable_ctrl_g : bool = true
## scales all light power
const scale_all_light_energy : float = 0.25
## ignore any VPLs with negligible energy
const vpl_energy_floor : float = 1e-5
## the colors for visualizing raycasts
const ray_hit_color := Color.LIGHT_GREEN
const ray_miss_color := Color.LIGHT_CORAL

# are we running in the editor
var in_editor : bool = Engine.is_editor_hint()

@export_category( "Scene Integration" )
## The node containing all the lights we wish to GI-ify
@export var top_node : Node3D = null
## A label if we want some status text
@export var label_node : Label = null
## Maximum number of Virtual Point Lights we can add to the scene to simulate GI
@export_range( 1, 1024 ) var max_vpls : int = 32
## Maximum number of directional sources we can add to the scene to simulate GI
@export_range( 1, 32 ) var max_directionals : int = 8
## What fraction of energy is preserved each bounce
@export_range( 0.0, 1.0, 0.01 ) var bounce_gain : float = 0.25
## What percent of oversamples use repeatable instead of changing pseudo-random
## vectors (low  values require heavier temporal filtering)
@export_range( 0.0, 100.0, 0.1 ) var percent_stable : float = 100.0
## Visualize the raycasts?
@export var show_raycasts : bool = false

@export_category( "Spot & Omni Lights" )
## How many VPLs to generate per source SpotLight3D, 1+
@export_range( 1, 8 ) var vpls_per_spot : int = 1:
		set( value ):
			vpls_per_spot = value
			light_data_stale = true
## How many VPLs to generate per source OmniLight3D, 1+ (>= 4 looks good)
@export_range( 1, 32 ) var vpls_per_omni : int = 4:
		set( value ):
			vpls_per_omni = value
			light_data_stale = true
## How many raycasts per VPL per _physics_process for spot and omni lights, 0+
@export_range( 0, 100 ) var oversample : int = 8
## Filter the VPLs over time (0=never update/infinite filtering, 1=instant update/no filtering)
@export_range( 0.01, 1.0, 0.005, "exp") var temporal_filter : float = 0.5
## place the VPL (0=at light origin, 1=at intersection)
@export_range( 0.0, 1.1, 0.01 ) var placement_fraction : float = 0.5

@export_category( "Directional Lights" )
## How many shared VPLs to approximate all DirectionalLight3D's.  A value
## of 0 will use a Virtual Directional Light per source instead (which is 
## a cheap but horrible approximation for indoors)
@export_range( 0, 16 ) var directional_vpls : int = 1:
		set( value ):
			directional_vpls = value
			light_data_stale = true
## How many raycasts per VPL per _physics_process for directional lights, 1+
@export_range( 1, 100 ) var oversample_dir : int = 16
## Do we want one additional VPL in the camera's looking vector? 0=no
@export var add_looking_VPL : bool = true:
		set( value ):
			add_looking_VPL = value
			light_data_stale = true
## Max distance for the placement of directional light bounces
@export var directional_proximity : float = 20.0
## Max distance to check for directional light being intercepted
@export var dir_scan_length : float = 100.0

@export_category( "Ambient" )
## Should this update the "Ambient Light" in a WorldEnvironment node?
@export var environment_node : WorldEnvironment = null
## How strong should this effect be
@export_range( 0.0, 1.0, 0.01 ) var ambient_gain : float = 0.25

# original light sources in the scene
var light_sources : Array[ Light3D ] = []
# track all (possibly noisy) VPL target data, indexed by the casting light and a sub-index
var VPL_targets : Dictionary[ Light3D, Dictionary ] = {}
# do we need to start fresh with the temporal data?
var light_data_stale : bool = true
# all directional lights share a set of VPLs, so we need a universal Key for our dictionaries
var token_directional_light := DirectionalLight3D.new() # don't attach

# keep a pool of our Virtual Points Lights
var VPL_inst : Array[ RID ] = []
var VPL_light : Array[ RID ] = []
var last_active_VPLs : int = 0
var active_VPLs : int = 0

# keep a pool of our Virtual Directional Lights
var VDL_inst : Array[ RID ] = []
var VDL_light : Array[ RID ] = []
var last_active_VDLs : int = 0
var active_VDLs : int = 0

# know where the camera is
var _camera : Camera3D = null

# physics stuff
var query := PhysicsRayQueryParameters3D.new()
var space_state : PhysicsDirectSpaceState3D = null
enum ray_storage { energy, pos, norm, rad, color, dist_frac }

# debug raycasts
var raycast_hits : PackedVector3Array = []
var raycast_misses : PackedVector3Array = []
@onready var draw_rays : ImmediateMesh = $RaycastDebug.mesh

func _unhandled_key_input( event ):
	# add the hotkey CTRL+G to toggle global illumination
	if enable_ctrl_g and (event is InputEventKey):
		if event.pressed and (event.keycode == KEY_G) and event.is_command_or_control_pressed():
			bounce_gain = 1.0 if (bounce_gain < 0.5) else 0.0
			get_viewport().set_input_as_handled()

# I need to raycast, which happens here in the physics process
func _physics_process( _delta ):
	active_VPLs = 0
	active_VDLs = 0
	allocate_VPLs( max_vpls )
	allocate_VDLs( max_directionals )
	raycast_hits.clear()
	raycast_misses.clear()
	if bounce_gain >= 0.01:
		# do I need to refresh all light data?
		if light_data_stale:
			VPL_targets = {}
		# now run through all active light sources in the scene
		var active_dir_lights : Array[ DirectionalLight3D ]
		for light in light_sources:
			if light.is_visible_in_tree() and (light.light_energy > 0.0):
				VPL_targets.get_or_add( light, {} )
				match light.get_class():
					"DirectionalLight3D": active_dir_lights.push_back( light )
					"OmniLight3D": process_omni( light )
					"SpotLight3D": process_spot( light )
			else:
				erase_light_data( light )
		# Directional lights
		handle_all_directional_lights( active_dir_lights )
		# do something with that info
		filter_and_emit_VPLs()
	else:
		VPL_targets.clear()
	
	if (bounce_gain < 0.01) or (ambient_gain < 0.01):
		disable_ambient_secondaries()
	
	# the user may wish to display raycasts
	draw_rays.clear_surfaces()
	if show_raycasts:
		if not raycast_hits.is_empty():
			draw_rays.surface_begin( Mesh.PRIMITIVE_LINES )
			for rce in raycast_hits:
				draw_rays.surface_add_vertex( rce )
			draw_rays.surface_set_color( ray_hit_color )
			draw_rays.surface_end()
		if not raycast_misses.is_empty():
			draw_rays.surface_begin( Mesh.PRIMITIVE_LINES )
			for rce in raycast_misses:
				draw_rays.surface_add_vertex( rce )
			draw_rays.surface_set_color( ray_miss_color )
			draw_rays.surface_end()
	# deactivate any VPLs that need it
	if active_VPLs < last_active_VPLs:
		for idx in range( active_VPLs, last_active_VPLs ):
			disable_VPL( idx )
	if last_active_VPLs != active_VPLs:
		last_active_VPLs = active_VPLs
		print( last_active_VPLs, " active VPLs" )
	# same for VDLs
	if active_VDLs < last_active_VDLs:
		for idx in range( active_VDLs, last_active_VDLs ):
			disable_VDL( idx )
	if last_active_VDLs != active_VDLs:
		last_active_VDLs = active_VDLs
		print( last_active_VDLs, " active VDLs" )
	# status?
	if label_node:
		if bounce_gain < 0.01:
			label_node.text = "FauxGI DISABLED"
		else:
			label_node.text = ("%d VPL, %d VDL, %1.4f amb " % 
				[ active_VPLs, active_VDLs, ambient_energy ] )

var ambient_energy : float = 0.0
func disable_ambient_secondaries():
	if environment_node and environment_node.environment:
		ambient_energy = 0.0
		environment_node.environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED

# cascaded exponential filtering
var VPL_filt_1 : Dictionary[ Light3D, Dictionary ] = {}
var VPL_filt_2 : Dictionary[ Light3D, Dictionary ] = {}
var VPL_filt_3 : Dictionary[ Light3D, Dictionary ] = {}

func erase_light_data( light : Light3D ):
	VPL_targets.erase( light )
	VPL_filt_1.erase( light )
	VPL_filt_2.erase( light )
	VPL_filt_3.erase( light )

func filter_and_emit_VPLs():
	if light_data_stale:
		VPL_filt_1.clear()
		VPL_filt_2.clear()
		VPL_filt_3.clear()
		light_data_stale = false
	# cascaded exponential filtering
	for light in VPL_targets:
		if not VPL_filt_1.has( light ):
			VPL_filt_1[ light ] = VPL_targets[ light ].duplicate( true )
			VPL_filt_2[ light ] = VPL_targets[ light ].duplicate( true )
			VPL_filt_3[ light ] = VPL_targets[ light ].duplicate( true )
		for idx in VPL_targets[ light ]:
			if not VPL_filt_1[ light ].has( idx ):
				VPL_filt_1[ light ][ idx ] = VPL_targets[ light ][ idx ].duplicate( true )
				VPL_filt_2[ light ][ idx ] = VPL_targets[ light ][ idx ].duplicate( true )
				VPL_filt_3[ light ][ idx ] = VPL_targets[ light ][ idx ].duplicate( true )
			for key in VPL_targets[ light ][ idx ]:
				# cascade in reverse order
				VPL_filt_3[ light ][ idx ][ key ] = lerp(
						VPL_filt_3[ light ][ idx ][ key ], 
						VPL_targets[ light ][ idx ][ key ],
						temporal_filter )
				VPL_filt_2[ light ][ idx ][ key ] = lerp(
						VPL_filt_2[ light ][ idx ][ key ], 
						VPL_filt_3[ light ][ idx ][ key ],
						temporal_filter )
				VPL_filt_1[ light ][ idx ][ key ] = lerp(
						VPL_filt_1[ light ][ idx ][ key ], 
						VPL_filt_2[ light ][ idx ][ key ],
						temporal_filter )
	# Gather all active VPLs into a convenient array
	var preVPLs : Array[ Dictionary ] = []
	for light in VPL_targets:
		for idx in VPL_targets[ light ]:
			if VPL_filt_1[ light ][ idx ][ ray_storage.energy ] > vpl_energy_floor:
				preVPLs.push_back( VPL_filt_1[ light ][ idx ] )
				# directional VPLs already have a color, but the token directional light does not
				preVPLs.back().get_or_add( ray_storage.color, light.light_color )
	# and do we want to modify ambient to simulate secondary+ bounces?
	if environment_node and environment_node.environment and (ambient_gain > 0.0):
		var global_color := Color(0,0,0,0)
		var global_energy : float = 0.0
		for preVPL in preVPLs:
			var r : float = 1.0 * preVPL[ ray_storage.rad ]
			var d : float = _camera.global_position.distance_to( preVPL[ ray_storage.pos ] )
			if d < r:
				var e : float = preVPL[ ray_storage.energy ] * sqrt(1.0 - d / r)
				global_color += preVPL[ ray_storage.color ] * e
				global_energy += e
		# and in case we are updating the environmental ambient...
		environment_node.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment_node.environment.ambient_light_color = global_color / global_energy
		ambient_energy = global_energy * ambient_gain
		environment_node.environment.ambient_light_energy = ambient_energy
		#print( global_energy )

	# Do we need a second pass to filter out the top N VPLs?
	if preVPLs.size() > max_vpls:
		# sort most to least energetic
		preVPLs.sort_custom( func(a, b): return a[ ray_storage.energy ] > b[ ray_storage.energy ] )
		# do I want to average all the lights that will get cut?
		if true:
			var avg_VPL : Dictionary = preVPLs[ 0 ]
			for key in avg_VPL:
				avg_VPL[ key ] *= 0.0
			var sum_energy : float = 0.0
			for idx in range( max_vpls - 1, preVPLs.size() ):
				var e : float = preVPLs[ idx ][ ray_storage.energy ]
				sum_energy += e;
				for key in preVPLs[ idx ]:
					avg_VPL[ key ] += preVPLs[ idx ][ key ] * e
			var gain : float = 1.0 / sum_energy
			for key in avg_VPL:
				avg_VPL[ key ] *= gain
			avg_VPL[ ray_storage.energy ] = sum_energy
		# just throw away the rest
		preVPLs.resize( max_vpls )
	# finally add the VPLs
	active_VPLs = 0
	for preVPL in preVPLs:
		config_VPL(	active_VPLs,
				preVPL[ ray_storage.pos ],
				preVPL[ ray_storage.color ], 
				preVPL[ ray_storage.energy ], 
				preVPL[ ray_storage.rad ] )
		active_VPLs += 1
	
func process_ray_dummy( from : Vector3, to : Vector3, done_frac : float = 0.5 ) -> Dictionary:
	# This function is only called if Oversample is 0, i.e. no raycasts
	var res_light : Dictionary
	var total_d : float = from.distance_to( to )
	var done_d : float = total_d * done_frac
	res_light[ ray_storage.pos ] = lerp( from, to, done_frac * placement_fraction )
	res_light[ ray_storage.norm ] = to.direction_to( from ) # just say the normal is back along this ray
	res_light[ ray_storage.rad ] = (total_d - 0.5 * done_d) * 1.25
	res_light[ ray_storage.energy ] = sqrt( 1.0 - done_frac )
	return res_light

var collisions : Dictionary = {}
func raycast( from : Vector3, to : Vector3 ) -> Dictionary:
	# do the ray cast
	query.from = from
	query.to = to
	var res_ray := space_state.intersect_ray( query )
	# draw it?
	if show_raycasts:
		if res_ray:
			raycast_hits.push_back( to_local( from ) )
			raycast_hits.push_back( to_local( res_ray.position ) )
		else:
			raycast_misses.push_back( to_local( from ) )
			raycast_misses.push_back( to_local( to ) )
	return res_ray
	
func process_single_ray( from : Vector3, to : Vector3 ) -> Dictionary:
	#
	var res_light : Dictionary
	var res_ray := raycast( from, to )
	if res_ray:
		var total_d : float = from.distance_to( to )
		var done_d : float = from.distance_to( res_ray.position )
		var done_frac : float = done_d / maxf( total_d, 1e-6 )
		res_light[ ray_storage.pos ] = lerp( from, to, done_frac * placement_fraction )
		res_light[ ray_storage.norm ] = res_ray.normal
		res_light[ ray_storage.rad ] = (total_d - 0.5 * done_d) * 1.25
		res_light[ ray_storage.energy ] = sqrt( 1.0 - done_frac ) \
					* absf( res_ray.normal.dot( from.direction_to( to ) ) )
	return res_light

func process_rays_average( from : Vector3, rays : PackedVector3Array ) -> Dictionary:
	var avg_ray_res : Dictionary
	var sum_energy : float = 0.0
	for ray in rays:
		var ray_res := process_single_ray( from, from + ray)
		if ray_res:
			# weight by energy
			var e = ray_res[ ray_storage.energy ]
			if e > 0.0:
				sum_energy += e
				ray_res[ ray_storage.pos ] *= e
				ray_res[ ray_storage.norm ] *= e
				ray_res[ ray_storage.rad ] *= e
				if not avg_ray_res:
					avg_ray_res = ray_res
				else:
					for key in ray_res:
						avg_ray_res[ key ] += ray_res[ key ]
	if avg_ray_res:
		# divide by energy
		var gain = 1.0 / sum_energy
		avg_ray_res[ ray_storage.pos ] *= gain
		avg_ray_res[ ray_storage.norm ] *= gain
		avg_ray_res[ ray_storage.rad ] *= gain
		# and the energy itself is scaled by the number of samples
		avg_ray_res[ ray_storage.energy ] = sum_energy / rays.size()
	return avg_ray_res

func raycast_average( rays_from_to : PackedVector3Array, 
			target : Vector3, look : Vector3, 
			dist : float ) -> Dictionary:
	var avg_ray_res : Dictionary
	var sum_score : float = 0.0
	for ray_idx in range( 0, rays_from_to.size(), 2 ):
		var res_ray := raycast( rays_from_to[ ray_idx ], rays_from_to[ ray_idx + 1 ] )
		if res_ray:
			var score : float = lerpf( 1.0, 0.1, clamp( 
					target.distance_to( res_ray.position ) / dist, 0.0, 1.0 ) )
			score *= max( 0.0, look.dot( res_ray.position - target ) )
			if (score > 0.0) and (look.dot( res_ray.normal ) < 0.0):
				sum_score += score
				if avg_ray_res:
					avg_ray_res[ ray_storage.pos ] += res_ray.position * score
					avg_ray_res[ ray_storage.norm ] += res_ray.normal * score
				else:
					avg_ray_res[ ray_storage.pos ] = res_ray.position * score
					avg_ray_res[ ray_storage.norm ] = res_ray.normal * score
	if avg_ray_res:
		avg_ray_res[ ray_storage.energy ] = 2.0 * sum_score / rays_from_to.size()
		avg_ray_res[ ray_storage.pos ] /= sum_score
		avg_ray_res[ ray_storage.norm ] /= sum_score
		# debug
		$DirCastDebug.global_position = avg_ray_res[ ray_storage.pos ]
	return avg_ray_res
	
func jitter_ray_angle(	ray : Vector3, N : int, deg : float, 
						percent_quasirandom : float = percent_stable ) -> PackedVector3Array:
	var rays : PackedVector3Array = []
	var length : float = -ray.length()
	var xform := Quaternion( Vector3(0,0,-1), ray )
	var rand_thresh : float = N * percent_quasirandom * 0.01
	var samp_2d : Vector2
	for samp in range( 0, N ):
		if (samp >= rand_thresh):
			samp_2d = (	Vector2( randf_range(-0.5, 0.5), randf_range(-0.5, 0.5) ) * 
						(deg / 120.0) + Vector2(0.5,0.5))
		else:
			samp_2d = qrnd_distrib( samp, deg / 120.0 )
		rays.push_back( (xform * Vector3.octahedron_decode( samp_2d )) * length )
	return rays

var cached_omni_rays : PackedVector3Array = []
func distribute_omni_rays( N : int ) -> PackedVector3Array:
	if N != cached_omni_rays.size():
		cached_omni_rays.clear()
		var remaining : int = 0
		match abs( N ):
			0:	# do nothing
				pass
			1:	# this is a single point
				cached_omni_rays.append( Vector3.DOWN )
			2:	# up and down
				const _two_dirs : Array[ Vector3 ] = [
						Vector3(0,+1,0), Vector3(0,-1,0) ]
				cached_omni_rays.append_array( _two_dirs )
			3: # 3 points in a plane (no up/down)
				const _three_dirs : Array[ Vector3 ] = [
						Vector3(1,0,0), Vector3(-0.6,0,0.8), Vector3(-0.6,0,-0.8) ]
				cached_omni_rays.append_array( _three_dirs )
			4, 5: # 4 faces of a tetrahedron, decent
				const _tds : float = 1.0 / sqrt( 3.0 )
				const _tet_dirs : Array[ Vector3 ] = [
						Vector3(1,1,-1) * _tds, Vector3(1,-1,1) * _tds,
						Vector3(-1,1,1) * _tds, Vector3(-1,-1,-1) * _tds ]
				cached_omni_rays.append_array( _tet_dirs )
				if N > 4:
					cached_omni_rays.append( Vector3.ONE )
			6, 7: # 6 faces of a cube (better), plus more if needed
				const _cube_dirs : Array[ Vector3 ] = [
						Vector3(0,0,+1), Vector3(0,0,-1),
						Vector3(0,+1,0), Vector3(0,-1,0),
						Vector3(+1,0,0), Vector3(-1,0,0) ]
				cached_omni_rays.append_array( _cube_dirs )
				# add extras randomly
				remaining = N - 6
			_:	# 8 points of a cube, plus extra
				for i in range(-1,2,2): # -1,1
					for j in range(-1,2,2): # -1,1
						for k in range(-1,2,2): # -1,1
							cached_omni_rays.append( Vector3(i,j,k).normalized() )
				# add extras randomly
				remaining = N - 8
		# we we need any extra?
		for i in remaining:
			cached_omni_rays.push_back( Vector3.octahedron_decode( 
										qrnd_distrib( i * 17 + 33 ) ) )
	return cached_omni_rays.duplicate()

func process_rays_angle( from : Vector3, to : Vector3, N : int, deg : float ) -> Dictionary:
	if N > 0:
		var rays := jitter_ray_angle( to - from, N, deg )
		return process_rays_average( from, rays )
	else:
		return process_ray_dummy( from, to, 0.5 )

func update_light_target( light : Light3D, idx : int, data : Dictionary, modulate : float ):
	if light and data:
		# scale in the actual light energy here
		data[ ray_storage.energy ] *= modulate * light.light_indirect_energy
		VPL_targets[ light ][ idx ] = data

func zero_light_target( light : Light3D, idx : int ):
	if light and VPL_targets.has( light ) and VPL_targets[ light ].has( idx ):
		VPL_targets[ light ][ idx ][ ray_storage.energy ] = 0.0

func process_light_rays( light : Light3D, rays : PackedVector3Array, angle_deg : float, modulate : float ):
	for ray_idx in rays.size():
		var ray_res := process_rays_angle( 
						light.global_position, 
						light.global_position + rays[ ray_idx ],
						oversample, angle_deg )
		if ray_res:
			update_light_target( light, ray_idx, ray_res, modulate )
			active_VPLs += 1
		else:
			zero_light_target( light, ray_idx )

func process_directional_light_rays(	lights : Array[ DirectionalLight3D ], 
										base_rays : PackedVector3Array, 
										angle_deg : float, modulate : float ):
	# the first ray may be special
	var jitter_angle : float = 45.0 if add_looking_VPL else angle_deg
	for ray_idx in base_rays.size():
		# oversample each base ray
		var N : int = max( 1, oversample_dir )
		var sum_color := Color(0,0,0,0)
		var sum_position := Vector3.ZERO
		var sum_normal := Vector3.ZERO
		var sum_energy : float = 0.0
		var rays := jitter_ray_angle( base_rays[ ray_idx ], N, jitter_angle )
		jitter_angle = angle_deg # for next time
		for ray in rays:
			# I don't want these raycasts draw, even in debug
			query.from = _camera.global_position
			query.to = _camera.global_position + ray
			var res := space_state.intersect_ray( query )
			if res:
				var norm : Vector3 = res.normal
				# we hit something, now see if the directional lights can hit it too
				for light in lights:
					var e : float = norm.dot( light.global_basis.z ) * light.light_energy
					if e > 0.0:
						# do a raycast to make sure the directional light doesn't hit anything
						var pos : Vector3 = lerp( _camera.global_position, res.position, 0.875 )
						if not raycast(		pos + light.global_basis.z * 0.001, 
											pos + light.global_basis.z * dir_scan_length ):
							sum_energy += e
							sum_color += light.light_color * e
							sum_position += pos * e
							sum_normal += norm * e
		if sum_energy > 0.0:
			var light_entry : Dictionary = {}
			light_entry[ ray_storage.energy ] = sum_energy / N
			light_entry[ ray_storage.pos ] = lerp( _camera.global_position, 
							sum_position / sum_energy, placement_fraction )
			light_entry[ ray_storage.norm ] = sum_normal / sum_energy
			light_entry[ ray_storage.color ] = sum_color / sum_energy
			#print( light_entry[ ray_storage.color ] )
			light_entry[ ray_storage.rad ] = directional_proximity * 2.0
			update_light_target( token_directional_light, ray_idx, light_entry, modulate )
			active_VPLs += 1
		else:
			zero_light_target( token_directional_light, ray_idx )

func handle_all_directional_lights( lights : Array[ DirectionalLight3D ] ):
	# like an omnilight, cast rays from the camera
	if lights:
		if (directional_vpls > 0) or add_looking_VPL:
			VPL_targets.get_or_add( token_directional_light, {} )
			
			var rays := distribute_omni_rays( directional_vpls )
			if add_looking_VPL: # add it to the front
				rays.insert( 0, -_camera.global_basis.z )
			for i in rays.size():
				rays[i] *= directional_proximity
			# do the ray casts
			var compensate_N_pts : float = 1.0 / rays.size()
			var angle_deg : float = sqrt( 14400.0 / max( 1, directional_vpls ) )
			process_directional_light_rays( lights, rays, angle_deg, 
							bounce_gain * compensate_N_pts )# * scale_all_light_energy )
		else:
			for light in lights:
				trivial_directional( light )
	else:
		erase_light_data( token_directional_light )

func trivial_directional( light : Light3D ):
	var e : float = (light.light_energy * light.light_indirect_energy * 
				scale_all_light_energy * bounce_gain)
	# directly place a Virtual Directional Light, instead of VPLs
	config_VDL( active_VDLs, light.global_basis.z, light.light_color, e )
	active_VDLs += 1

func process_spot( light : Light3D ):
	var compensate_N_pts : float = 1.0 / vpls_per_spot
	# these rays never use real random jitter
	var rays := jitter_ray_angle( -light.spot_range * light.global_basis.z, 
									vpls_per_spot, light.spot_angle, 100.0 )
	process_light_rays( light, rays, light.spot_angle * sqrt( compensate_N_pts ), 
		light.light_energy * bounce_gain * scale_all_light_energy * compensate_N_pts )

func process_omni( light : Light3D ):
	# where do I want to cast rays, and size them correctly
	var rays := distribute_omni_rays( vpls_per_omni )
	for i in rays.size():
		rays[i] *= light.omni_range
	# do the ray casts
	var compensate_N_pts : float = 1.0 / rays.size()
	var angle_deg : float = sqrt( 14400.0 * compensate_N_pts )
	process_light_rays( light, rays, angle_deg, 
			light.light_energy * bounce_gain * scale_all_light_energy * compensate_N_pts )

func _ready():
	# grab the camera
	if in_editor:
		# Get EditorInterface this way because it does not exist in a build
		var editor_interface := Engine.get_singleton( "EditorInterface" )
		_camera = editor_interface.get_editor_viewport_3d().get_camera_3d()
	else:
		_camera = get_viewport().get_camera_3d()
	# set up for raycasts (which are all in global space)
	space_state = get_world_3d().direct_space_state
	# find all possible source lights
	var source_nodes : Array[ Node ]
	if top_node:
		# the user told us where to look
		source_nodes = top_node.find_children("", "Light3D" )
	else:
		# no user direction, try the parent of the FauxGI node
		var parent = get_parent()
		if parent:
			source_nodes = parent.find_children("", "Light3D" )
	if source_nodes:
		# store all vetted light sources
		for sn_light : Light3D in source_nodes:
			# maybe only look at lights which cast shadows
			if sn_light.shadow_enabled or include_shadowless:
				light_sources.push_back( sn_light )
		# report
		print( "Source count is ", light_sources.size() )
		print( "VPL max count is ", VPL_light.size() )

func qrnd_distrib( index : int, scale_01 : float = 1.0 ) -> Vector2:
	const mid2d := Vector2.ONE * 0.5
	const golden_2d := 1.32471795724474602596
	const g2 := Vector2( 1.0 / golden_2d, 1.0 / golden_2d / golden_2d )
	return ( ( mid2d + g2 * index ).posmod( 1.0 ) - mid2d) * scale_01 + mid2d;

func _enter_tree():
	allocate_VPLs( max_vpls )

func _exit_tree():
	allocate_VPLs( 0 )

func allocate_VPLs( N : int ):
	if N != VPL_inst.size():
		# safety first
		N = max( 0, min( max_vpls, N ) )
		print( "VPL count ", VPL_inst.size(), " -> ", N )
		# do we need to remove some RIDs?
		while VPL_inst.size() > N:
			RenderingServer.free_rid( VPL_inst.pop_back() )
		while VPL_light.size() > N:
			RenderingServer.free_rid( VPL_light.pop_back() )
		# do we need to add some RIDs?
		var scenario = get_world_3d().scenario
		while VPL_inst.size() < N:
			# spot is slightly slower, but alternating lets the engine render 8 omni + 8 spot per mesh
			var spot_instead : bool = ((VPL_inst.size() & 1) == 1) and VPLs_use_spots
			# each light needs an instance, attached to the scenario
			var instance : RID = RenderingServer.instance_create()
			RenderingServer.instance_set_scenario( instance, scenario )
			# create and attach the light (each light needs different parameters, 
			# so we can't just share a single light across multiple instances)
			var light : RID
			if spot_instead:
				light = RenderingServer.spot_light_create()
			else:
				light = RenderingServer.omni_light_create()
			RenderingServer.instance_set_base( instance, light )
			# configure any constant parameters here
			RenderingServer.instance_set_visible( instance , false )
			RenderingServer.light_set_param( light, RenderingServer.LIGHT_PARAM_SPECULAR, 0.0 )
			if spot_instead:
				RenderingServer.light_set_param( light, RenderingServer.LIGHT_PARAM_SPOT_ANGLE, 180.0 )
			# keep a copy around
			VPL_inst.append( instance )
			VPL_light.append( light )

func disable_VPL( index : int ):
	if index < VPL_inst.size():
		RenderingServer.instance_set_visible( VPL_inst[ index ] , false )

func config_VPL(	index : int,
					pos : Vector3,
					color : Color,
					energy : float,
					dist : float ):
	if index < min( VPL_inst.size(), VPL_light.size() ):
		# instance parameters
		var inst : RID = VPL_inst[ index ]
		RenderingServer.instance_set_visible( inst , true )
		RenderingServer.instance_set_transform( inst, Transform3D( Basis.IDENTITY, pos ) )
		# light parameters
		var light : RID = VPL_light[ index ]
		RenderingServer.light_set_color( light, color )
		RenderingServer.light_set_param( light, RenderingServer.LIGHT_PARAM_ENERGY, energy )
		RenderingServer.light_set_param( light, RenderingServer.LIGHT_PARAM_RANGE, dist )

func allocate_VDLs( N : int ):
	if N != VDL_inst.size():
		# safety first
		N = max( 0, min( max_directionals, N ) )
		print( "VDL count ", VDL_inst.size(), " -> ", N )
		# do we need to remove some RIDs?
		while VDL_inst.size() > N:
			RenderingServer.free_rid( VDL_inst.pop_back() )
		while VDL_light.size() > N:
			RenderingServer.free_rid( VDL_light.pop_back() )
		# do we need to add some RIDs?
		var scenario = get_world_3d().scenario
		while VDL_inst.size() < N:
			# each light needs an instance, attached to the scenario
			var instance : RID = RenderingServer.instance_create()
			RenderingServer.instance_set_scenario( instance, scenario )
			# create and attach the light (each light needs different parameters, 
			# so we can't just share a single light across multiple instances)
			var light : RID = RenderingServer.directional_light_create()
			RenderingServer.instance_set_base( instance, light )
			# configure any constant parameters here
			RenderingServer.instance_set_visible( instance , false )
			RenderingServer.light_set_param( light, RenderingServer.LIGHT_PARAM_SPECULAR, 0.0 )
			# keep a copy around
			VDL_inst.append( instance )
			VDL_light.append( light )

func disable_VDL( index : int ):
	if index < VDL_inst.size():
		RenderingServer.instance_set_visible( VDL_inst[ index ] , false )

func config_VDL(	index : int,
					direction : Vector3,
					color : Color,
					energy : float ):
	if index < min( VDL_inst.size(), VDL_light.size() ):
		# instance parameters
		var inst : RID = VDL_inst[ index ]
		RenderingServer.instance_set_visible( inst , true )
		RenderingServer.instance_set_transform( inst, 
				Transform3D( Quaternion( Vector3(0,0,-1), direction ), Vector3.ZERO ) )
		# light parameters
		var light : RID = VDL_light[ index ]
		RenderingServer.light_set_color( light, color )
		RenderingServer.light_set_param( light, RenderingServer.LIGHT_PARAM_ENERGY, energy )

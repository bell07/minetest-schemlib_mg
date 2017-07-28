--local dprint = print
local dprint = function() return end
local modpath = minetest.get_modpath(minetest.get_current_modname())
local filepath = modpath.."/buildings/"



schemlib_mg = {
	rarity = 0.002,
	async_delay = 0.01,
}

local func = {} -- different functions
local building_checktable = {}

local tmp_next_plan
--------------------------------------
-- Plan manager singleton
--------------------------------------
local plan_manager = {
	plan_list = {}
}
schemlib_mg.plan_manager = plan_manager

--------------------------------------
-- Restore active WIP plan's
--------------------------------------
function plan_manager:restore()
	self.stored_list = schemlib.save_restore.restore_data("/schemlib_mg.store")
	for plan_id, entry in pairs(self.stored_list) do
		local filename = building_checktable[entry.filename]
		if filename then
			local plan = func.get_plan_from_file(entry.filename, modpath.."/buildings/"..entry.filename, plan_id, entry.anchor_pos)
			if entry.facedir ~= nil then
				plan.facedir = entry.facedir
			end
			if entry.mirrored ~= nil then
				plan.mirrored = entry.mirrored
			end
		end
	end
end

--------------------------------------
-- Save active WIP plan's
--------------------------------------
function plan_manager:save()
	self.stored_list = {}
	for plan_id, plan in pairs(self.plan_list) do
		if plan.schemlib_builder_mg_filename then
			local entry = {
				anchor_pos = plan.anchor_pos,
				filename   = plan.schemlib_mg_building_filename,
				facedir    = plan.facedir,
				mirrored   = plan.mirrored,
			}
			self.stored_list[plan_id] = entry
		end
	end
	schemlib.save_restore.save_data("/schemlib_mg.store", self.stored_list)
end

--------------------------------------
-- Get known plan
--------------------------------------
function plan_manager:get(plan_id)
	local plan = self.plan_list[plan_id]
	if plan and plan:get_status() == "finished" then
		dprint("plan finished, remove from mg plan manager")
		self:set_finished(plan)
		return nil
	else
		return plan
	end
end

--------------------------------------
-- Set the plan finished
--------------------------------------
function plan_manager:set_finished(plan)
	minetest.after(5, function(plan_id)
		self.plan_list[plan.plan_id] = nil
		plan_manager:save()
	end, plan.plan_id)
end

--------------------------------------
-- Add new plan to the list
--------------------------------------
function plan_manager:add(plan)
	self.plan_list[plan.plan_id] = plan
end

--------------------------------------
-- set anchor and rename to get active
--------------------------------------
function plan_manager:activate_by_anchor(anchor_pos)
	local plan = tmp_next_plan
	tmp_next_plan = nil
	local new_plan_id = minetest.pos_to_string(anchor_pos)
	plan.plan_id = new_plan_id
	plan.anchor_pos = anchor_pos
	plan:set_status("build")
	self.plan_list[new_plan_id] = plan
	self:save()
	return plan
end

--------------------------------------
-- Functions
--------------------------------------
-- Get buildings list
--------------------------------------
function func.get_buildings_list()
	local list = {}
	local building_files = minetest.get_dir_list(modpath.."/buildings/", false)
	for _, file in ipairs(building_files) do
		table.insert(list, {name=file, filename=modpath.."/buildings/"..file})
		building_checktable[file] = true
	end
	return list
end

--------------------------------------
-- Load plan from file and configure them
--------------------------------------
function func.get_plan_from_file(name, filename, plan_id, anchor_pos)
	plan_id = plan_id or name
	local plan = schemlib.plan.new(plan_id, anchor_pos)
	plan.schemlib_mg_building_filename = name
	plan:read_from_schem_file(filename)
	plan:apply_flood_with_air()
	if anchor_pos then
		plan:set_status("build")
		plan_manager:add(plan)
	end
	return plan
end

--------------------------------------
-- do it
--------------------------------------
function func.take_the_build(pos)
	if not tmp_next_plan then
		-- no plan in list - and no plan temporary loaded - load them (maybe)
		local building = schemlib_mg.buildings[math.random(#schemlib_mg.buildings)]
		dprint("File selected for build", building.filename)
		tmp_next_plan = func.get_plan_from_file(building.name, building.filename)
		tmp_next_plan.facedir = math.random(4)-1
		tmp_next_plan.mirrored = (math.random(2) == 1)
		dprint("building loaded. Nodes:", tmp_next_plan.data.nodecount)
		minetest.after(schemlib_mg.async_delay, func.take_the_build, pos) --try again after the waiting
		return
	end


	-- check for possible overlaps with other plans
	for plan_id, plan in pairs(plan_manager.plan_list) do
		if tmp_next_plan:check_overlap(plan:get_world_minp(), plan:get_world_maxp(), 8, pos) then
			dprint("plan overlap")
			return
		end
	end

		-- take the anchor proposal
	local anchor_pos =  tmp_next_plan:propose_anchor(pos, true)
	dprint("anchor proposed", anchor_pos)
	if not anchor_pos then
		return
	end

	local plan = plan_manager:activate_by_anchor(anchor_pos)
	if plan then
		dprint("call async for", plan.plan_id)
		minetest.after(schemlib_mg.async_delay, func.instant_build_chunk, plan.plan_id)
	end
end

--------------------------------------
-- build chunk async
--------------------------------------
function func.instant_build_chunk(plan_id)
	local plan = plan_manager:get(plan_id)
	if not plan then
		return
	end
	dprint("chung build running", plan_id)

	local random_pos = plan:get_random_plan_pos()
	if not random_pos then
		return
	end

	dprint("build chunk", minetest.pos_to_string(random_pos))

	plan:do_add_chunk_voxel(random_pos)
	-- chunk done handle next chunk call
	dprint("nodes left:", plan.data.nodecount)
	if plan:get_status() == "build" then
		--start next plan chain
		minetest.after(schemlib_mg.async_delay, func.instant_build_chunk, plan_id)
	else
		plan_manager:set_finished(plan)
		return
	end
end


--------------------------------------
-- Process the seed if node loaded using lbm
--------------------------------------
function func.process_seed(pos)
	minetest.after(schemlib_mg.async_delay, func.take_the_build, pos)
	minetest.remove_node(pos)
end


-- Node definition
minetest.register_node("schemlib_mg:seed", {
	description = "Schemlib building seed",
	drawtype = "airlike",
	groups = {not_in_creative_inventory = 1},
	on_construct = func.process_seed
})

-- Mapgen
minetest.register_decoration({
		deco_type = "simple",
		place_on = {"default:dirt_with_grass", "default:dirt_with_dry_grass", "default:dirt_with_snow", "default:sand"},
		sidelen = 16,
		fill_ratio = schemlib_mg.rarity,
-- 		noise_params TODO
		decoration = "schemlib_mg:seed",
})


-- Activate
minetest.register_lbm({
	name = "schemlib_mg:seed",
	nodenames = {"schemlib_mg:seed"},
	run_at_every_load = true,
	action = func.process_seed,
})

-- Restore data at init
schemlib_mg.buildings = func.get_buildings_list() -- at init!
plan_manager:restore()


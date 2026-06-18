--!optimize 2

local globalenv = getgenv and getgenv() or _G or shared
local globalcontainer = globalenv.globalcontainer

if not globalcontainer then
	globalcontainer = {}
	globalenv.globalcontainer = globalcontainer
end

local genvs = {}
if getgenv then table.insert(genvs, getgenv()) end
table.insert(genvs, shared)
table.insert(genvs, _G)
-- if getrenv then 
-- 	table.insert(genvs, 1, getrenv())
-- end
-- if debug and debug.getregistry then
-- 	table.insert(genvs, 1, debug.getregistry()._LOADED)
-- end

-- Calculate actual physical call limit safely by breaking Tail-Call Optimization
local calllimit = 0
do
	local function determineCalllimit()
		calllimit = calllimit + 1
		local _ = determineCalllimit() + 0 -- Adding + 0 forces Luau to keep the stack frame alive
	end
	pcall(determineCalllimit)
	
	-- Apply a safety buffer. If Luau crashed at 200, we don't want to hit exactly 200.
	calllimit = math.max(10, calllimit - 5) 
end

local function isEmpty(dict)
	for _ in next, dict do
		return false
	end
	return true
end

-- State variables scoped for finder runs
local depth, printresults, hardlimit, query, antioverflow, matchedall 

local function recurseEnv(env, envname)
	if globalcontainer == env then
		return
	end
	if antioverflow[env] then
		return
	end
	antioverflow[env] = true

	depth = depth + 1
	for name, val in next, env do
		if matchedall then
			break
		end

		local Type = type(val)

		if Type == "table" then
			if depth < hardlimit then
				recurseEnv(val, tostring(name))
			end
		elseif Type == "function" then 
			local stringName = string.lower(tostring(name))
			local matched
			
			for methodname, pattern in next, query do
				if pattern(stringName, envname) then
					globalcontainer[methodname] = val
					if not matched then
						matched = {}
					end
					table.insert(matched, methodname)
					if printresults then
						print("Found:", methodname, "->", name, "in", envname)
					end
				end
			end
			
			if matched then
				for _, methodname in next, matched do
					query[methodname] = nil
				end
				matchedall = isEmpty(query)
				if matchedall then
					break
				end
			end
		end
	end
	depth = depth - 1
end

local function finder(Query, ForceSearch, CustomCallLimit, PrintResults)
	antioverflow = {}
	query = {}
	matchedall = false

	do -- Load patterns
		local function Find(String, Pattern)
			return string.find(String, Pattern, nil, true)
		end
		for methodname, pattern in next, Query do
			if not globalcontainer[methodname] or ForceSearch then
				if not Find(pattern, "return") then
					pattern = "return " .. pattern
				end
				local success, result = pcall(loadstring, pattern)
				if success and result then
					query[methodname] = result
				else
					warn("Failed to load pattern for " .. tostring(methodname))
				end
			end
		end
	end

	-- If everything requested is already cached and ForceSearch isn't true, exit early
	if isEmpty(query) then 
		return finder, globalcontainer 
	end

	depth = 0
	printresults = PrintResults
	hardlimit = CustomCallLimit or calllimit

	-- Unpack genvs array and scan each root environment individually
	for _, env in next, genvs do
		if matchedall then break end
		recurseEnv(env, "root_env")
	end

	-- Fallback to __index inheritance
	do
		local env = getfenv()
		for methodname in next, Query do
			if not globalcontainer[methodname] then
				globalcontainer[methodname] = env[methodname]
			end
		end
	end

	-- Clean up state references to free up memory
	hardlimit = nil
	depth = nil
	printresults = nil
	antioverflow = nil
	query = nil
	matchedall = nil
end

return finder, globalcontainer
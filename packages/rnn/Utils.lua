local Class = createClass{name="Utils",bases={"base.Object"}};

require 'torch'
require 'nn'
require 'nngraph'
require 'optim'
require 'lfs'

local model_utils = require 'utils.model_utils'

--[[
Class: rnn.Utils

Utils class for RNN construction

This class inherits from <base.Object>.
]]

--[=[
--[[
Constructor: Utils

Create a new instance of the class.

Parameters:
   No parameter
]]
function Utils(options)
]=]
function Class:initialize(options)
	self:debug("Creating RNN Utils.")
	-- We use float tensors in this project:
	torch.setdefaulttensortype('torch.FloatTensor')
end


--[[
Function: setupGPU

Setup for the common GPU elements
]]
function Class:setupGPU(opt)
	self:debug("Setting up RNN GPU support.")
	CHECK(opt.seed~=nil,"Invalid seed value")
	CHECK(opt.gpuid~=nil,"Invalid gpuid value")
	CHECK(opt.opencl~=nil,"Invalid opencl value")
	
	torch.manualSeed(opt.seed)

	-- initialize cunn/cutorch for training on the GPU and fall back to CPU gracefully
	if opt.gpuid >= 0 and opt.opencl == 0 then
		self:debug("Initializing GPU support with CUDA...")
	  local ok, cunn = pcall(require, 'cunn')
	  local ok2, cutorch = pcall(require, 'cutorch')
	  if not ok then self:warn('package cunn not found!') end
	  if not ok2 then self:warn('package cutorch not found!') end
	  if ok and ok2 then
	    self:debug('using CUDA on GPU ' .. opt.gpuid .. '...')
	    cutorch.setDevice(opt.gpuid + 1) -- note +1 to make it 0 indexed! sigh lua
	    cutorch.manualSeed(opt.seed)
	  else
	    self:warn('If cutorch and cunn are installed, your CUDA toolkit may be improperly configured.')
	    self:warn('Check your CUDA toolkit installation, rebuild cutorch and cunn, and try again.')
	    self:warn('Falling back on CPU mode')
	    opt.gpuid = -1 -- overwrite user setting
	  end
	end

	-- initialize clnn/cltorch for training on the GPU and fall back to CPU gracefully
	if opt.gpuid >= 0 and opt.opencl == 1 then
		self:debug("Initializing GPU support with OpenCL...")
	  local ok, cunn = pcall(require, 'clnn')
	  local ok2, cutorch = pcall(require, 'cltorch')
	  if not ok then self:warn('package clnn not found!') end
	  if not ok2 then self:warn('package cltorch not found!') end
	  if ok and ok2 then
	    self:debug('using OpenCL on GPU ' .. opt.gpuid .. '...')
	    cltorch.setDevice(opt.gpuid + 1) -- note +1 to make it 0 indexed! sigh lua
	    torch.manualSeed(opt.seed)
	  else
	    self:warn('If cltorch and clnn are installed, your OpenCL driver may be improperly configured.')
	    self:warn('Check your OpenCL driver installation, check output of clinfo command, and try again.')
	    self:warn('Falling back on CPU mode')
	    opt.gpuid = -1 -- overwrite user setting
	  end
	end
end

--[[
Function: createLSTM

Method used to create an LSTM prototype
]]
function Class:createLSTM(opt)
	CHECK(opt.num_layers,"Invalid num_layers")
	CHECK(opt.rnn_size,"Invalid rnn_size")
	CHECK(opt.dropout,"Invalid dropout")
	CHECK(opt.num_inputs,"Invalid num_inputs")
	CHECK(opt.num_outputs,"Invalid num_outputs")

	local input_size = opt.num_inputs
	local output_size = opt.num_outputs
	local rnn_size = opt.rnn_size
	local n = opt.num_layers
	local dropout = opt.dropout

	self:debug("Number of LSTM inputs: ".. opt.num_inputs)
	self:debug("Number of LSTM outputs: ".. opt.num_outputs)

  dropout = dropout or 0 

  -- there will be 2*n+1 inputs
  local inputs = {}
  table.insert(inputs, nn.Identity()()) -- x
  for L = 1,n do
    table.insert(inputs, nn.Identity()()) -- prev_c[L]
    table.insert(inputs, nn.Identity()()) -- prev_h[L]
  end

  local x, input_size_L
  local outputs = {}
  for L = 1,n do
    -- c,h from previos timesteps
    local prev_h = inputs[L*2+1]
    local prev_c = inputs[L*2]
    -- the input to this layer
    if L == 1 then 
      -- x = OneHot(input_size)(inputs[1])
      x = nn.Identity()(inputs[1])
      input_size_L = input_size
    else 
      x = outputs[(L-1)*2] 
      if dropout > 0 then x = nn.Dropout(dropout)(x) end -- apply dropout, if any
      input_size_L = rnn_size
    end
    -- evaluate the input sums at once for efficiency
    local i2h = nn.Linear(input_size_L, 4 * rnn_size)(x):annotate{name='i2h_'..L}
    local h2h = nn.Linear(rnn_size, 4 * rnn_size)(prev_h):annotate{name='h2h_'..L}
    local all_input_sums = nn.CAddTable()({i2h, h2h})

    local reshaped = nn.Reshape(4, rnn_size)(all_input_sums)
    local n1, n2, n3, n4 = nn.SplitTable(2)(reshaped):split(4)
    -- decode the gates
    local in_gate = nn.Sigmoid()(n1)
    local forget_gate = nn.Sigmoid()(n2)
    local out_gate = nn.Sigmoid()(n3)
    -- decode the write inputs
    local in_transform = nn.Tanh()(n4)
    -- perform the LSTM update
    local next_c           = nn.CAddTable()({
        nn.CMulTable()({forget_gate, prev_c}),
        nn.CMulTable()({in_gate,     in_transform})
      })
    -- gated cells form the output
    local next_h = nn.CMulTable()({out_gate, nn.Tanh()(next_c)})
    
    table.insert(outputs, next_c)
    table.insert(outputs, next_h)
  end

  -- set up the decoder
  local top_h = outputs[#outputs]
  if dropout > 0 then top_h = nn.Dropout(dropout)(top_h) end
  
  local proj = nn.Linear(rnn_size, output_size)(top_h):annotate{name='decoder'}
  
  if output_size == 1 then
    -- after the dropout, we need to compute a linear single value,
    -- and apply a sigmoid on it to get value in the range (0,1)
    local final = nn.Sigmoid()(proj)
    table.insert(outputs, final)
  else
    local logsoft = nn.LogSoftMax()(proj)
    table.insert(outputs, logsoft)
  end

  return nn.gModule(inputs, outputs)
end

--[[
Function: createPrototype

Method used to create the RNN prototype
]]
function Class:createPrototype(opt)
	CHECK(opt.model=="lstm","Invalid RNN model")

	self:debug('Creating an ' .. opt.model .. ' with ' .. opt.num_layers .. ' layers')
	
	local protos = {}
	if opt.model == 'lstm' then
	  protos.rnn = self:createLSTM(opt)
	else
		self:throw("Unsupported RNN model: ", opt.model)
	end

	if opt.num_outputs == 1 then
		protos.criterion = nn.MSECriterion()	
	else
		protos.criterion = nn.ClassNLLCriterion()
	end

	-- ship the model to the GPU if desired
	if opt.gpuid >= 0 and opt.opencl == 0 then
	  for k,v in pairs(protos) do 
	    -- log:debug("Converting ",k," to GPU...")
	    v:cuda() 
	  end
	end

	if opt.gpuid >= 0 and opt.opencl == 1 then
	  for k,v in pairs(protos) do 
	    v:cl() 
	  end
	end

	return protos
end

--[[
Function: isUpdateRequired

Helper method used to check if a given file used as source
was updated (eg. modified) after a product file was generated
from that source
]]
function Class:isUpdateRequired(src,prod)
  local src_attr = lfs.attributes(src)
  local prod_attr = lfs.attributes(prod)

  return src_attr.modification > prod_attr.modification
end

--[[
Function: readCSV

Helper method used to read a CSV file into a tensor
]]
function Class:readCSV(filename, nrows, ncols, withtags)
  -- Read data from CSV to tensor
  local csvFile = io.open(filename, 'r')  
  local header = csvFile:read()

  local data = torch.Tensor(nrows, ncols)
  local timetags = nil
  if withtags then
    timetags = torch.LongTensor(nrows)
  end

  local i = 0  
  for line in csvFile:lines('*l') do  
    i = i + 1
    local l = line:split(',')
    if timetags then
      timetags[i] = table.remove(l,1)
    end
    for key, val in ipairs(l) do
      data[i][key] = val
    end
  end

  csvFile:close()

  return data, timetags
end

--[[
Function: loadRawInputs

Method used to load the raw inputs
]]
function Class:loadRawInputs(opt,fname)
	CHECK(opt.data_dir,"Invalid data_dir")
	local dataDir = opt.data_dir

	local dcfg = dofile(path.join(dataDir, 'dataset.lua'))

	fname = fname or "raw_inputs"

	local src = path.join(dataDir, fname ..".csv")
  local dest = path.join(dataDir, fname ..".t7")
	local tagsfile = path.join(dataDir, fname .."_timetags.t7")

	if not path.exists(dest) or self:isUpdateRequired(src,dest) then
		self:debug('Preprocessing: generating file ', dest, '...')
	  local timer = torch.Timer()

	  self:debug('Preprocessing ',dcfg.num_samples,' samples...')

	  local data, timetags = self:readCSV(src,dcfg.num_samples,dcfg.num_inputs,opt.with_timetag==1)
	  
	  -- save the tensor to file:
    torch.save(dest, data)
	  if timetags then
      torch.save(tagsfile, timetags)
    end

	  self:debug('Preprocessing completed in ' .. timer:time().real .. ' seconds')
	end

  local data = torch.load(dest)

  local timetags = nil
  if opt.with_timetag == 1 then
    self:debug("Extracting timetags...")
    timetags = torch.load(tagsfile)
    self:debug("Found timetags: ", timetags:narrow(1,1,10))
  end

	return data, timetags
end

--[[
Function: getNumSymbols

Retrieve the number of symbols considered in a given raw inputs dataset
]]
function Class:getNumSymbols(opt,inputs)
  local np = inputs:size(2) - 2
  return np/(opt.with_close_only==1 and 1 or 4)	
end

--[[
Function: normalizeTimes

Method called to normalize the times
]]
function Class:normalizeTimes(features)
  self:debug("Normalizing times...")
  local daylen = 24*60
  local weeklen = 5*daylen

  -- features[{{},1}] = (features[{{},1}]/weeklen - 0.5)*2.0
  -- features[{{},2}] = (features[{{},2}]/daylen - 0.5)*2.0  

  -- use the range [0,1]
  features[{{},1}] = features[{{},1}]/weeklen
  features[{{},2}] = features[{{},2}]/daylen
end


--[[
Function: computeEMA

Method used to compute an EMA feature from a vector
]]
function Class:computeEMA(vec, period)
  self:debug("Feature ",self._idx,": EMA with period ",period)

  -- compute the coeff:
  -- cf. http://stockcharts.com/school/doku.php?id=chart_school:technical_indicators:moving_averages
  local mult =  (2 / (period + 1))

  -- Prepare the result vector:
  local res = vec:clone()
  local ema = res:storage()[1]

  res:apply(function(x)
    ema = (x-ema)*mult + ema
    return ema
  end)

  -- Normalize the feature:
  self:normalizeFeature(res)
  
  -- convert to sigmoid:
  self:sigmoid(res)

  self:incrementFeatureIndex()

  return res
end

--[[
Function: normalizeFeature

Method used to normalize a feature vector
]]
function Class:normalizeFeature(cprice,cmean,csig)
  cmean = cmean or self._fMeans[self._idx] or cprice:mean(1):storage()[1]
  csig = csig or self._fDevs[self._idx] or cprice:std(1):storage()[1]

  cprice[{}] = (cprice-cmean)/csig

  self:debug("Normalizing feature ", self._idx,": mean=",cmean,", dev=",csig)

  -- Save the normalization details
  self._fMeans[self._idx] = cmean
  self._fDevs[self._idx] = csig

  return cmean, csig
end

--[[
Function: sigmoid

Convert a vector to sigmoid:
]]
function Class:sigmoid(vec)
  vec[{}] = torch.pow(torch.exp(-vec)+1.0,-1.0)
end

--[[
Function: incrementFeatureIndex

Increment the current feature index
]]
function Class:incrementFeatureIndex()
  self._idx = self._idx + 1
end

--[[
Function: computeLogReturn

Method used to compute a log return of a given price vector 
with a provided offset
]]
function Class:computeLogReturn(vec, offset, period)
  self:debug("Feature ",self._idx,": Log return with offset ",offset)

  -- Prepare the result vector:
  local res = vec:clone()

  local rets = torch.cdiv(vec[{{1+offset,-1}}],vec[{{1,-1-offset}}])
  
  res[{{1,offset}}] = 1.0
  res[{{1+offset,-1}}] = rets

  -- Also take the log:
  res:log()

  if period and period>1 then
    local mult =  (2 / (period + 1))
    local ema = res:storage()[1]
    
    res:apply(function(x)
      ema = (x-ema)*mult + ema
      return ema
    end)    
  end

  -- Normalize the feature:
  self:normalizeFeature(res)
  
  -- convert to sigmoid:
  self:sigmoid(res)

  self:incrementFeatureIndex()

  return res
end

--[[
Function: computeREMA

Method used to compute an REMA feature from a vector
]]
function Class:computeREMA(vec, period)
  self:debug("Feature ",self._idx,": REMA with period ",period)

  -- compute the coeff:
  -- cf. http://stockcharts.com/school/doku.php?id=chart_school:technical_indicators:moving_averages
  local mult =  (2 / (period + 1))

  -- Prepare the result vector:
  local res = vec:clone()
  local ema = 0.0 
  local prevVal = res:storage()[1]

  res:apply(function(x)
    local lret = math.log(x/prevVal)
    prevVal = x
    ema = (lret-ema)*mult + ema
    return ema
  end)

  -- Normalize the feature:
  self:normalizeFeature(res)
  
  -- convert to sigmoid:
  self:sigmoid(res)

  self:incrementFeatureIndex()

  return res
end

--[[
Function: computeRSI

Method used to compute an RSI feature from a vector
The input for this method should be the price vector
]]
function Class:computeRSI(vec, period)
  self:debug("Feature ",self._idx,": RSI with period ",period)

  -- compute the coeff:
  -- cf. https://fr.wikipedia.org/wiki/Relative_strength_index
  
  local mult =  (2 / (period + 1))

  -- Prepare the result vector:
  local res = vec:clone()
  local H = 0.001
  local B = 0.001

  local prevVal = res:storage()[1]

  res:apply(function(x)
    -- Retrieve the new price:
    -- if the increment is positive then we update H:
    if x > prevVal then
      H = (x-prevVal) * mult + H * (1.0 - mult)
    end

    -- Otherwise we update B:
    if x < prevVal then
      B = (prevVal - x) * mult + B * (1.0 - mult)
    end

    -- update the previous price value:
    prevVal = x

    -- compute the RSI (value will be between 0 and 1)
    return H/(H+B)
  end)

  --  RSI doesn't need normalization of sigmoid processing: it will always be in the range [0,1]

  -- Normalize the feature:
  -- self:normalizeFeature(res)
  
  -- convert to sigmoid:
  -- self:sigmoid(res)

  self:incrementFeatureIndex()

  return res
end

--[[
Function: split

Helper method used to split strings
]]
function Class:split(inputstr, sep)
  if sep == nil then
    sep = ","
  end
  local t={} ; i=1
  for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
    t[i] = str
    i = i + 1
  end
  return t
end

--[[
Function: generateLogReturnFeatures

Method used to generate the log returns features from a raw_inputs tensor
]]
function Class:generateLogReturnFeatures(opt,prices,timetags)
  CHECK(opt.ema_base_period,"Invalid ema_base_period")
  CHECK(opt.num_emas,"Invalid num_emas")
  CHECK(opt.num_remas,"Invalid num_emas")
  CHECK(opt.rsi_period,"Invalid rsi_period")
  CHECK(opt.log_return_offsets,"Invalid log_return_offsets")
  CHECK(opt.log_return_ema_period,"Invalid log_return_ema_period")
  CHECK(opt.feature_offset or opt.warmup_offset,"Invalid feature_offset")
  CHECK(opt.num_input_symbols,"Invalid num_input_symbols")

  local warmup_offset = opt.warmup_offset or opt.feature_offset

  self:debug("Generating log return features...")

  -- Retrive the number of symbols:
  local nsym = opt.num_input_symbols

  -- print("Initial prices: ", prices:narrow(1,1,10))

  -- retrive the raw number of samples:
  local nrows = prices:size(1)

  -- Check if we want the moving averages:
  local numEMAs = opt.num_emas
  local numREMAs = opt.num_remas
  local baseEMAPeriod = opt.ema_base_period
  local rsiPeriod = opt.rsi_period
  local numRSI = (rsiPeriod>0 and 1 or 0)
  local logOffsets = self:split(opt.log_return_offsets)
  local logEMAPeriod = opt.log_return_ema_period
  local numLogOffsets = #logOffsets

  local nf = 2+nsym + nsym*numEMAs + nsym*numREMAs + nsym*numRSI + nsym*numLogOffsets

  -- for each symbol we keep on the close prices,
  -- So we prepare a new tensor of the proper size:
  local features = torch.Tensor(nrows,nf)

  -- populate this new tensor:
  -- copy the week and day times:
  features[{{},{1,2}}] = prices[{{},{1,2}}]

  self._fMeans = opt.feature_means or {}
  self._fDevs = opt.feature_devs or {}

  -- copy the close prices:
  local offset = 2
  self._idx = 1

  local period, loff
  local istride = opt.with_close_only==1 and 1 or 4

  for i=1,nsym do   
    -- Retrieve the raw prices:
    local cprices = prices[{{},offset+istride*i}]

    -- build the main logReturn feature:
    features[{{},offset+self._idx}] = self:computeLogReturn(cprices,1)

    -- Also generate the additional log returns for each symbol:
    for j=1,numLogOffsets do
      loff = logOffsets[j]
      features[{{},offset+self._idx}] = self:computeLogReturn(cprices,loff,logEMAPeriod) 
    end

    -- Also generate the EMAs for each symbol:
    for j=1,numEMAs do
      period = baseEMAPeriod*math.pow(2,j-1)
      features[{{},offset+self._idx}] = self:computeEMA(cprices,period) 
    end

    -- Also generate the REMAs for each symbol:
    for j=1,numREMAs do
      period = baseEMAPeriod*math.pow(2,j-1)
      features[{{},offset+self._idx}] = self:computeREMA(cprices,period) 
    end

    --  Also generate the RSI for each symbol:
    if rsiPeriod > 0 then
      features[{{},offset+self._idx}] = self:computeRSI(cprices,rsiPeriod) 
    end
  end

  opt.feature_means = self._fMeans
  opt.feature_devs = self._fDevs

  -- remove the start offset lines of the features:
  -- print("Feature before norm: ",features:narrow(1,1,10))
  features = features:sub(1+warmup_offset,-1)

  if timetags then
    timetags = timetags:sub(1+warmup_offset,-1)
    CHECK(timetags:size(1)==features:size(1),"Mismatch with timetags size.")
  end

  -- Now apply normalization of the times value:
  self:normalizeTimes(features)
  -- print("Normalized times: ", features:narrow(1,1,10))

  return features, timetags
end

-- preprocessing helper function
function Class:prepro(opt, x)
  -- x = x:transpose(1,2):contiguous() -- swap the axes for faster indexing
  x = x:contiguous() -- swap the axes for faster indexing
  
  if opt.gpuid >= 0 and opt.opencl == 0 then -- ship the input arrays to GPU
    -- have to convert to float because integers can't be cuda()'d
    x = x:float():cuda()
  end

  if opt.gpuid >= 0 and opt.opencl == 1 then -- ship the input arrays to GPU
    x = x:cl()
  end

  return x
end


--[[
Function: generateLogReturnLabels

Method used to generate the labels from the features
]]
function Class:generateLogReturnLabels(opt, features, timetags)
  self:debug("Generating log return labels")
  CHECK(opt.forcast_index,"Invalid forcast_index")
  CHECK(opt.num_classes,"Invalid num_classes")
  CHECK(opt.label_offset>0,"Invalid label_offset")

  -- Now generate the desired labels:
  -- The label is just the next value of the sigmoid transformed log returns
  -- labels will be taken from a given symbol index:

  self:debug("Forcast feature index: ", opt.forcast_index)

  local offset = 2
  local idx = offset+opt.forcast_index
  local labels = features:sub(1+opt.label_offset,-1,idx,idx)

  -- Should remove the last row from the features:
  features = features:sub(1,-1-opt.label_offset)
  if timetags then
    timetags = timetags:sub(1,-1-opt.label_offset)
    CHECK(timetags:size(1)==features:size(1),"Mismatch with timetags size: ",timetags:size(1),"!=",features:size(1) )
  end

  -- print("Generated log return labels: ", labels:narrow(1,1,10))

  if opt.num_classes > 1 then
    labels = self:generateClasses(labels,0,1,opt.num_classes)
  end

  -- print("Labels classes: ", labels:narrow(1,1,10))
  if timetags then
    local vals = {}
    for i = 1,10 do 
      table.insert(vals,timetags[i])
    end
    -- print("Final timetags: ", vals)
  end
  -- print("Final features: ", features:narrow(1,1,10))

  return features, labels, timetags
end

--[[
Function: generateClasses

Method used to generated classes for a given vector
]]
function Class:generateClasses(labels,rmin,rmax,nclasses)
  -- We now have normalized labels,
  -- but what we are interested in is in classifying the possible outputs:
  -- First we clamp the data with the max range (as number of sigmas):
  -- we assume here that we can replace the content of the provided vector.
  local eps = 1e-6
  labels = labels:clamp(rmin,rmax - eps)

  -- Now we cluster the labels in the different classes:
  self:debug("Number of classes: ", nclasses)
  local range = rmax - rmin
  self:debug("Labels range: ", range)
  local classSize = range/nclasses
  self:debug("Label class size: ", classSize)

  -- The labels classes should be 1 based, so we add 1 below:
  labels = torch.floor((labels - rmin)/classSize) + 1  

  return labels
end

--[[
Function: createInitState

Create the init state that will be used to store the current
initial state of the RNN
]]
function Class:createInitState(opt, bsize)
	self:debug("Creating init state.")

	-- the initial state of the cell/hidden states
  bsize = bsize or (opt.batch_size < 0 and 1 or opt.batch_size)

	local init_state = {}
	for L=1,opt.num_layers do
	  local h_init = torch.zeros(bsize, opt.rnn_size)
	  if opt.gpuid >=0 and opt.opencl == 0 then h_init = h_init:cuda() end
	  if opt.gpuid >=0 and opt.opencl == 1 then h_init = h_init:cl() end
	  table.insert(init_state, h_init:clone())
	  if opt.model == 'lstm' then
	    table.insert(init_state, h_init:clone())
	  end
	end

	return init_state
end

--[[
Function: cloneList

Method used to clone a list of tensor
]]
function Class:cloneList(tensor_list, zero_too)
  -- takes a list of tensors and returns a list of cloned tensors
  local out = {}
  for k,v in pairs(tensor_list) do
      out[k] = v:clone()
      if zero_too then out[k]:zero() end
  end
  return out	
end

--[[
Function: initParameters

Method called to perform parameter initialization
]]
function Class:initParameters(opt,proto)
	self:debug("Initializing parameters...")
	
	-- put the above things into one flattened parameters tensor
	local params, grad_params = model_utils.combine_all_parameters(proto.rnn)
	-- log:debug("Number of parameters: ", params:nElement())

	-- initialization:
	local randomInitNeeded = true
	if randomInitNeeded then
	  params:uniform(-0.08, 0.08) -- small uniform numbers
	end

	-- initialize the LSTM forget gates with slightly higher biases to encourage remembering in the beginning
	if opt.model == 'lstm' then
	  for layer_idx = 1, opt.num_layers do
	    for _,node in ipairs(proto.rnn.forwardnodes) do
	      if node.data.annotations.name == "i2h_" .. layer_idx then
	        self:debug('Setting forget gate biases to 1 in LSTM layer ' .. layer_idx)
	        -- the gates are, in order, i,f,o,g, so f is the 2nd block of weights
	        node.data.module.bias[{{opt.rnn_size+1, 2*opt.rnn_size}}]:fill(1.0)
	      end
	    end
	  end
	end

	self:debug('Number of parameters in the model: ' .. params:nElement())

	return params, grad_params
end

--[[
Function: generateClones

Method used to generate the clones of the protoype
]]
function Class:generateClones(opt, protos)
	self:debug("Generating clones...")
	CHECK(opt.seq_length,"Invalid seq_length")

	-- make a bunch of clones after flattening, as that reallocates memory
	clones = {}
	for name,proto in pairs(protos) do
	  self:debug('Cloning ' .. name)
	  clones[name] = model_utils.clone_many_times(proto, opt.seq_length, not proto.parameters)
	end

	return clones
end

--[[
Function: evaluate

Method used to evaluate the prediction on a given input
]]
function Class:evaluate(opt, tdesc)
  tdesc.grad_params:zero()

  ------------------ get minibatch -------------------
  local index = tdesc.train_offset+tdesc.iteration
  local x = tdesc.features:narrow(1,index, opt.seq_length)
  local y = tdesc.labels:narrow(1,index, opt.seq_length)

  -- self:debug("Evaluating with features tensor: ", x)

  -- self:debug("Evaluating from feature index ",index)
  -- self:debug("First Evaluation label: ", y[opt.seq_length])
  -- self:debug("Previous label: ", y[opt.seq_length-1])

  ------------------- forward pass -------------------
  local rnn_state = {[0] = tdesc.global_eval_state}
  -- local predictions = {}           -- softmax outputs
  local loss = 0
  local pred;

  -- observing dimensions of seq_length x batch_size below:
  -- print("x dimensions: ",x:size(1),"x",x:size(2))
  -- print("y dimensions: ",y:size(1),"x",y:size(2))
  local len = opt.seq_length

  for t=1,len do
    tdesc.clones.rnn[t]:evaluate() -- make sure we are in correct mode (this is cheap, sets flag)
    local lst = tdesc.clones.rnn[t]:forward{x:narrow(1,t,1), unpack(rnn_state[t-1])}

    -- print("x[".. t.."]:", x[t])
    -- line below will always return #lst=5 (with 2 layers)
    -- and  #lst=7 with 3 layers 
    -- This correspond to the description of the LSTM model (2 outputs per layers + final output)
    -- print("Size of lst is: ".. #lst .. " at seq = "..t)

    -- We anticipate that the value below should be 4 when we have 2 layers: OK
    -- print("Size of init_state: ".. #init_state)

    rnn_state[t] = {}
    for i=1,#tdesc.init_state do table.insert(rnn_state[t], lst[i]) end -- extract the state, without output

    -- override the prediction value each time: we only need the latest one:
    pred = lst[#lst]


    -- predictions[t] = lst[#lst] -- last element is the prediction
    -- self:debug("predictions[",t,"] dims= ",predictions[t]:nDimension(),": ",predictions[t]:size(1),"x",predictions[t]:size(2))
    -- self:debug("y[",t,"] dims= ",y[t]:nDimension(),": ",y[t]:size(1))

    -- loss = loss + tdesc.clones.criterion[t]:forward(predictions[t], y[t])
    -- self:debug("New loss value: ",loss)
  end


	-- The loss should only be considered on the latest prediction:
	loss = tdesc.clones.criterion[len]:forward(pred, y[len])
  -- loss = loss / opt.seq_length

  -- Update the global init state:
  -- tdesc.global_eval_state = rnn_state[1]
  -- clone the tensor to ensure we get a separated copy:
  local src = rnn_state[1]
  for k,tens in ipairs(src) do
    tdesc.global_eval_state[k] = tens:clone()
  end

  -- if we use a classifier, then we should extract the classification weights:
  -- self:debug("Prediction are: ", pred)
  
  pred = pred:storage()[1]
  local yval = y[{len,1}]

	return loss, pred, yval 
end

--[[
Function: trainEval

Core method used during training.
Do fwd/bwd and return loss, grad_params
]]
function Class:trainEval(opt, tdesc, x)
  if x ~= tdesc.params then
    tdesc.params:copy(x)
  end
  tdesc.grad_params:zero()

  ------------------ get minibatch -------------------
  local idx = tdesc.iteration
  local x,y;
  if opt.batch_size > 0 then
    x = tdesc.x_batches[idx]
    y = tdesc.y_batches[idx]
  else
    x = tdesc.features:narrow(1,tdesc.train_offset+idx, opt.seq_length)
    y = tdesc.labels:narrow(1,tdesc.train_offset+idx, opt.seq_length)
  end

  ------------------- forward pass -------------------
  local rnn_state = {[0] = tdesc.global_init_state}
  local predictions = {}           -- softmax outputs
  local loss = 0

  -- observing dimensions of seq_length x batch_size below:
  -- print("x dimensions: ",x:size(1),"x",x:size(2))
  -- print("y dimensions: ",y:size(1),"x",y:size(2))
  local bsize = opt.batch_size > 0 and opt.batch_size or 1

  for t=1,opt.seq_length do
    tdesc.clones.rnn[t]:training() -- make sure we are in correct mode (this is cheap, sets flag)
    local input = bsize == 1 and x:narrow(1,t,1) or x[t]

    local lst = tdesc.clones.rnn[t]:forward{input, unpack(rnn_state[t-1])}

    -- print("x[".. t.."]:", x[t])
    -- line below will always return #lst=5 (with 2 layers)
    -- and  #lst=7 with 3 layers 
    -- This correspond to the description of the LSTM model (2 outputs per layers + final output)
    -- print("Size of lst is: ".. #lst .. " at seq = "..t)

    -- We anticipate that the value below should be 4 when we have 2 layers: OK
    -- print("Size of init_state: ".. #init_state)

    rnn_state[t] = {}
    for i=1,#tdesc.init_state do table.insert(rnn_state[t], lst[i]) end -- extract the state, without output

    predictions[t] = lst[#lst] -- last element is the prediction
    -- self:debug("predictions[",t,"] dims= ",predictions[t]:nDimension(),": ",predictions[t]:size(1),"x",predictions[t]:size(2))
    -- self:debug("y[",t,"] dims= ",y[t]:nDimension(),": ",y[t]:size(1))

    loss = loss + tdesc.clones.criterion[t]:forward(predictions[t], y[t])
    -- self:debug("New loss value: ",loss)
  end
  loss = loss / opt.seq_length
  
  ------------------ backward pass -------------------
  -- initialize gradient at time t to be zeros (there's no influence from future)
  local drnn_state = {[opt.seq_length] = self:cloneList(tdesc.init_state, true)} -- true also zeros the tdesc.clones
  for t=opt.seq_length,1,-1 do
    -- backprop through loss, and softmax/linear
    local doutput_t = tdesc.clones.criterion[t]:backward(predictions[t], y[t])
    table.insert(drnn_state[t], doutput_t)
    
    local input = bsize == 1 and x:narrow(1,t,1) or x[t]

    local dlst = tdesc.clones.rnn[t]:backward({input, unpack(rnn_state[t-1])}, drnn_state[t])
    drnn_state[t-1] = {}
    for k,v in pairs(dlst) do
      if k > 1 then -- k == 1 is gradient on x, which we dont need
          -- note we do k-1 because first item is dembeddings, and then follow the 
          -- derivatives of the state, starting at index 2. I know...
        drnn_state[t-1][k-1] = v
      end
    end
  end
  
  ------------------------ misc ----------------------
  -- transfer final state to initial state (BPTT)
  -- here we use only the subsequence rnn_state, not the final one,
  -- because the next sequence will start with the next time step, and not
  -- the final sequence time step.
  tdesc.global_init_state = rnn_state[1]

  -- note that we only keep the latest state from the latest batch because this is where
  -- we will start the evaluation from:
  -- local src = rnn_state[#rnn_state]
  -- also note that we start from the state 1 for this global state too as we will
  -- take the first (seq_len - 1) element for the first sequence from the training set.

  -- For now, we do not assign any evaluation state at all:
  -- local src = rnn_state[1]
  -- for k,tens in ipairs(src) do
  --   tdesc.global_eval_state[k] = tens[bsize]
  -- end

  -- tdesc.global_init_state = rnn_state[#rnn_state] -- NOTE: I don't think this needs to be a clone, right?
  -- self._grad_params:div(opt.seq_length) -- this line should be here but since we use rmsprop it would have no effect. Removing for efficiency
  -- clip gradient element-wise
  tdesc.grad_params:clamp(-opt.grad_clip, opt.grad_clip)
  return loss, tdesc.grad_params
end

--[[
Function: prepareMiniBatchFeatures

Method used to prepare the mini batch features and labels
for a given training session
]]
function Class:prepareMiniBatchFeatures(opt, tdesc)
  -- So, we know that we are only going to use train_size rows,
  -- starting from train_offset index, so we can narrow this down:
  self:debug("Preparing Mini batch features/labels...")
  local nrows = opt.train_size
  -- self:debug("Number of rows: ", nrows)
  -- self:debug("Available rows: ",tdesc.raw_features:size(1))

  local features = tdesc.raw_features:narrow(1,tdesc.train_offset+1, nrows)
  local labels = tdesc.raw_labels:narrow(1,tdesc.train_offset+1, nrows)

  -- Complete length of the sequence in each batch:
  local seq_len = opt.seq_length

  local nbatches = opt.seq_length * opt.batch_num_seqs
  local bsize = opt.batch_size
  local nf = tdesc.raw_features:size(2)

  local x_batches = {}
  local y_batches = {}
  
  local stride = opt.seq_length * opt.batch_num_seqs
  
  local offset = 0
  local idx;

  for i=1,nbatches do
    local xbatch = torch.Tensor(seq_len,bsize,nf)
    local ybatch = torch.Tensor(seq_len,bsize)

    for t=1,seq_len do
      -- build a tensor corresponding to the sequence element t
      -- eg. we present all the rows of features in batch that arrive
      -- at time t in the sequence:
      local xmat = torch.Tensor(bsize,nf)
      local ymat = torch.Tensor(bsize)

      -- fill the data for this tensor:
      for i=1,bsize do
        idx = offset+(i-1)*stride+t
        xmat[{i,{}}] = features[{idx,{}}]
        ymat[i] = labels[idx]
      end

      xbatch[t] = xmat
      ybatch[t] = ymat
    end

    table.insert(x_batches,self:prepro(opt,xbatch))
    table.insert(y_batches,self:prepro(opt,ybatch))
    
    offset = offset + 1    
  end

  tdesc.x_batches = x_batches
  tdesc.y_batches = y_batches
  self:debug("Done preparing Mini batch features/labels.")
end

--[[
Function: performTrainSession

Method used to perform a train session
]]
function Class:performTrainSession(opt, tdesc)
	CHECK(opt.learning_rate,"Invalid learning_rate")
	CHECK(opt.decay_rate,"Invalid decay_rate")
	CHECK(opt.max_epochs,"Invalid max_epochs")
	CHECK(opt.train_size,"Invalid train_size")
	CHECK(opt.seq_length,"Invalid seq_length")
	CHECK(opt.accurate_gpu_timing,"Invalid accurate_gpu_timing")
	CHECK(opt.learning_rate_decay,"Invalid learning_rate_decay")
	CHECK(opt.learning_rate_decay_after,"Invalid learning_rate_decay_after")
  CHECK(opt.print_every,"Invalid print_every")
  CHECK(opt.ema_adaptation,"Invalid ema_adaptation")
  CHECK(opt.optim,"Invalid optim")
  CHECK(opt.batch_size,"Invalid batch_size")
	CHECK(opt.batch_num_seqs,"Invalid batch_num_seqs")

	-- start optimization here
	tdesc.train_losses = tdesc.train_losses or {}
	-- local val_losses = {}

	local optim_state = {}
  -- rmsprop state:
  optim_state.learningRate = opt.learning_rate
  optim_state.alpha = opt.decay_rate
  
  -- conjugate gradient state:
  optim_state.maxEval = 6
  optim_state.maxIter = 2

	-- The number of iteration is the number of times we can extract a sequence of seq_length
	-- in the train_size, numtiplied by the number of epochs we allow:
	local ntrain_by_epoch = (opt.train_size - opt.seq_length + 1)

  -- Note that, if the batch_size is specified, then the number of iterations in each
  -- epoch is given by opt.batch_num_seqs*opt.seq_length:
  if opt.batch_size > 0 then
    ntrain_by_epoch = opt.batch_num_seqs*opt.seq_length

    -- If we use minibatch, then we also need to setup the features/labels 
    -- appropriately:
    self:prepareMiniBatchFeatures(opt,tdesc)
  end

  -- Upload the raw features/labels if needed:
  -- but we keep a CPU version untouched as we might need it
  -- to generate the subsequent x/y batches.
  tdesc.features = self:prepro(opt,tdesc.raw_features:clone())
  tdesc.labels = self:prepro(opt,tdesc.raw_labels:clone())

  tdesc.ntrain_per_epoch = ntrain_by_epoch

	local iterations = opt.max_epochs * ntrain_by_epoch
	local loss0 = nil

  local optimfunc = optim.rmsprop
  -- Change the optimization function if needed:
  if opt.optim == 'cg' then
    optimfunc = optim.cg
  end

	local feval = function(x)
		return self:trainEval(opt, tdesc, x)
	end

  tdesc.iteration = 0
	for i = 1, iterations do
	  local epoch = i / ntrain_by_epoch
	  
    tdesc.iteration = tdesc.iteration + 1
    if tdesc.iteration > tdesc.ntrain_per_epoch then
      tdesc.iteration = 1
    end

	  local timer = torch.Timer()

	  local _, loss = optimfunc(feval, tdesc.params, optim_state)
	  if opt.accurate_gpu_timing == 1 and opt.gpuid >= 0 then
	    --[[
	    Note on timing: The reported time can be off because the GPU is invoked async. If one
	    wants to have exactly accurate timings one must call cutorch.synchronize() right here.
	    I will avoid doing so by default because this can incur computational overhead.
	    --]]
	    cutorch.synchronize()
	  end
	  local time = timer:time().real
	  
	  local train_loss = loss[1] -- the loss is inside a list, pop it
	  table.insert(tdesc.train_losses, train_loss)

	  -- exponential learning rate decay
	  -- if i % ntrain_by_epoch == 0 and opt.learning_rate_decay < 1 then
	  --   if epoch >= opt.learning_rate_decay_after then
	  --     local decay_factor = opt.learning_rate_decay
	  --     optim_state.learningRate = optim_state.learningRate * decay_factor -- decay it
	  --     self:debug('Decayed learning rate by a factor ' .. decay_factor .. ' to ' .. optim_state.learningRate)
	  --   end
	  -- end

	  -- every now and then or on last iteration
	  -- if i % opt.eval_val_every == 0 or i == iterations then
	  --   -- evaluate loss on validation data
	  --   local val_loss = self:evaluateSplit(2) -- 2 = validation
	  --   val_losses[i] = val_loss

	  --   local savefile = string.format('%s/lm_%s_epoch%.2f_%.4f.t7', opt.checkpoint_dir, opt.savefile, epoch, val_loss)
	  --   self:debug('Saving checkpoint to ' .. savefile)
	  --   local checkpoint = {}
	  --   checkpoint.protos = self._prototype
	  --   checkpoint.opt = opt
	  --   checkpoint.train_losses = train_losses
	  --   checkpoint.val_loss = val_loss
	  --   checkpoint.val_losses = val_losses
	  --   checkpoint.i = i
	  --   checkpoint.epoch = epoch
	  --   self._provider:addCheckpointData(checkpoint)
	  --   torch.save(savefile, checkpoint)
	  -- end

	  if i % opt.print_every == 0 then
	    self:debug(string.format("%d/%d (epoch %.3f), train_loss = %6.8f, grad/param norm = %6.4e, time/batch = %.4fs", i, iterations, epoch, train_loss, tdesc.grad_params:norm() / tdesc.params:norm(), time))
	  end
	 
	  if i % 10 == 0 then collectgarbage() end

	  -- handle early stopping if things are going really bad
	  if loss[1] ~= loss[1] then
	    self:warn('loss is NaN.  This usually indicates a bug.  Please check the issues page for existing issues, or create a new issue, if none exist.  Ideally, please state: your operating system, 32-bit/64-bit, your blas version, cpu/cuda/cl?')
	    break -- halt
	  end

	  if loss0 == nil then loss0 = loss[1] end
	  if loss[1] > loss0 * 300 then
	    self:warn('loss is exploding, aborting.')
	    break -- halt
	  end
	end

  local lastx = tdesc.x_batches[tdesc.ntrain_per_epoch]
  local lasty = tdesc.y_batches[tdesc.ntrain_per_epoch]
  -- self:debug("Last train xbatch: ", lastx)
  -- self:debug("Previous train label: ", lasty[opt.seq_length-1][opt.batch_size])
  -- self:debug("Last train label: ", lasty[opt.seq_length][opt.batch_size])

	tdesc.eval_losses = tdesc.eval_losses or {}
  tdesc.correct_signs = tdesc.correct_signs or {}
  tdesc.evalidx_values = tdesc.evalidx_values or {}
  tdesc.timetags_values = tdesc.timetags_values or {}
  tdesc.pred_values = tdesc.pred_values or {}
	tdesc.label_values = tdesc.label_values or {}

	tdesc.current_sign = tdesc.current_sign or 0.5

	local alpha = opt.ema_adaptation

  -- Start the evaluation just after the train samples:
  -- note that the first (seq_len-1) observations are taken from the
  -- training set, so we have to account for this offset:
  -- Additionally note that the +1 is done in the loop below directly:
  -- First major error here: the last training sequence started on
  -- opt.train_size - opt.seq_length **+ 1** 
  tdesc.iteration = opt.train_size - opt.seq_length + 1

  tdesc.eval_offset = tdesc.eval_offset or opt.train_size

	-- Now that we are done with the training part we should evaluate the network predictions:
  self:debug("Starting evaluation at offset position: ", tdesc.eval_offset)

	for i=1,opt.eval_size do

		--  Move to the nex iteration each time:
    tdesc.eval_offset = tdesc.eval_offset + 1
  	tdesc.iteration = tdesc.iteration + 1 
		local loss, pred, yval = self:evaluate(opt, tdesc)

    self:debug("Prediction: ", pred, ", real value: ",yval)

    table.insert(tdesc.timetags_values, tdesc.timetags and tdesc.timetags[tdesc.eval_offset] or tdesc.eval_offset)
    table.insert(tdesc.evalidx_values,i)
    table.insert(tdesc.pred_values,pred)
    table.insert(tdesc.label_values,yval)

    -- We also check if we have the proper sign for the prediction:
    local goodSign = 0

    if opt.num_classes == 1 and ((pred-0.5) * (yval-0.5) > 0.0) then
      goodSign = 1
    elseif opt.num_classes > 1 and (pred - opt.num_classes/2 - 0.5) * (yval - opt.num_classes - 0.5) > 0.0 then
      goodSign = 1 
    end

		tdesc.current_loss = tdesc.current_loss and (tdesc.current_loss * (1.0 - alpha) + loss * alpha) or loss
		table.insert(tdesc.eval_losses,tdesc.current_loss)

    if opt.num_classes == 1 then
  		tdesc.current_sign = (tdesc.current_sign * (1.0 - alpha) + goodSign * alpha)
    end

    table.insert(tdesc.correct_signs, tdesc.current_sign)
		-- self:debug("Evaluation ",i,": Loss EMA=",tdesc.current_loss,", correct sign EMA=",tdesc.current_sign)
	end

  self:evaluatePredictionStats(opt,tdesc)
end

--[[
Function: correlation

Compute the correlation between 2 tables of the same length
]]
function Class:correlation(a,b)
  CHECK(#a == #b, "Mismatch in table lengths")
  local len = #a
  if len < 3 then
    return 0.0
  end

  -- Compute the mean of the arrays:
  local sa = 0.0
  local sb = 0.0
  local sab = 0.0
  local saa = 0.0
  local sbb = 0.0

  for i=1,len do
    sa = sa + a[i]
    sb = sb + b[i]
    sab = sab + a[i]*b[i]
    saa = saa + a[i]*a[i]
    sbb = sbb + b[i]*b[i]
  end

  sa = sa / len
  sb = sb / len
  -- sab = sab / len
  -- saa = saa / len
  -- sbb = sbb / len

  -- Formula from: https://en.wikipedia.org/wiki/Pearson_product-moment_correlation_coefficient#Mathematical_properties
  local rho = (sab - len*sa*sb)/(math.sqrt(saa - len*sa*sa)*math.sqrt(sbb - len*sb*sb))
  return rho
end

--[[
Function: evaluatePredictionStats

Method used to evaluate the current statistics on the generated predictions
]]
function Class:evaluatePredictionStats(opt,tdesc)
  
  -- Compute the stats for each steps and for a given threshold level
  local res = torch.Tensor(10,opt.eval_size*3):zero()

  local len = #tdesc.pred_values

  -- for each possible threshold we have to collect the value of interest:
  for i=1,10 do
    for n=1,opt.eval_size do 
      local thres = (i-1)/10
      local preds = {}
      local labels = {}

      local good = 0

      for j=1,len do
        local p = (tdesc.pred_values[j]-0.5)*2.0
        local b = (tdesc.label_values[j]-0.5)*2.0

        if math.abs(p) > thres and tdesc.evalidx_values[j] == n then
          good = good + (p*b>0.0 and 1.0 or 0.0)

          table.insert(preds, p)
          table.insert(labels, b)
        end
      end

      -- Compute the correlation between those vectors:
      res[i][3*n-2] = #preds
      res[i][3*n-1] = #preds>0 and good/#preds or 0
      res[i][3*n] = self:correlation(preds,labels)
    end
  end

  self:debug("Correlation results for step 2:\n",res:narrow(2,4,3))
end

--[[
Function: writeArray
]]
function Class:writeArray(filename,array)
  local file = io.open(filename,"w")
  for _,v in ipairs(array) do
    file:write(v.."\n")
  end
  file:close()
end

--[[
Function: writeArrays

Method used to write multiple arrays to file
]]
function Class:writeArrays(filename,arrays,headers)
  local file = io.open(filename,"w")
  if headers then
    file:write(table.concat(headers,", ") .."\n")
  end

  local narr = #arrays
  local len = #arrays[1]
  for i=1,len do
    local tt = {}
    for j=1,narr do
      table.insert(tt,arrays[j][i])
    end

    file:write(table.concat(tt,", ") .."\n")
  end
  file:close()
end


return Class()

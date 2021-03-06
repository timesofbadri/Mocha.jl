type CuDNNPoolingState
  pooling_desc :: CuDNN.PoolingDescriptor
  inputs_desc  :: Vector{CuDNN.Tensor4dDescriptor}
  outputs_desc :: Vector{CuDNN.Tensor4dDescriptor}

  # TODO: used for explicit padding when needed, as CuDNN does not
  # support padded pooling. See below.
  padded_blobs      :: Vector{Blob}
  padded_blobs_diff :: Vector{Blob}
end

function setup_etc(sys::System{CuDNNBackend}, layer::PoolingLayer, inputs,
    pooled_width, pooled_height)

  dtype = eltype(inputs[1])
  width = get_width(inputs[1])
  height = get_height(inputs[1])

  if isa(layer.pooling, Pooling.Max)
    pooling_mode = CuDNN.CUDNN_POOLING_MAX
  elseif isa(layer.pooling, Pooling.Mean)
    pooling_mode = CuDNN.CUDNN_POOLING_AVERAGE
  else
    error("TODO: pooling mode $(layer.pooling) not supported by CuDNN")
  end
  pooling_desc = CuDNN.create_pooling_descriptor(pooling_mode, layer.kernel, layer.stride)
  inputs_desc = Array(CuDNN.Tensor4dDescriptor, length(inputs))
  outputs_desc = Array(CuDNN.Tensor4dDescriptor, length(inputs))

  if layer.pad[1] == 0 && layer.pad[2] == 0
    for i = 1:length(inputs)
      inputs_desc[i] = CuDNN.create_tensor4d_descriptor(dtype,
          (width,height,get_chann(inputs[i]),get_num(inputs[i])))
      outputs_desc[i] = CuDNN.create_tensor4d_descriptor(dtype,
          (pooled_width,pooled_height,get_chann(inputs[i]),get_num(inputs[i])))
    end
    etc = CuDNNPoolingState(pooling_desc, inputs_desc, outputs_desc, Blob[], Blob[])
  else
    # TODO: CuDNN does not support pooling with padding yet, I think that instead
    # of implementing our own pooling in GPU, it should be easier and computationally
    # more efficient to do explicit padding and call the CuDNN pooling. If in the
    # future CuDNN supports pooling with padding, this workaround could be removed.
    padded_width = width + 2*layer.pad[1]
    padded_height = height + 2*layer.pad[2]
    padded_blobs = Array(Blob, length(inputs))
    padded_blobs_diff = Array(Blob, length(inputs))
    for i = 1:length(inputs)
      padded_blobs[i] = make_blob(sys.backend, dtype, padded_width, padded_height,
          get_chann(inputs[i]), get_num(inputs[i]))
      padded_blobs_diff[i] = make_blob(sys.backend, dtype, padded_width, padded_height,
          get_chann(inputs[i]), get_num(inputs[i]))

      inputs_desc[i] = CuDNN.create_tensor4d_descriptor(dtype,
          (padded_width,padded_height,get_chann(inputs[i]),get_num(inputs[i])))
      outputs_desc[i] = CuDNN.create_tensor4d_descriptor(dtype,
          (pooled_width,pooled_height,get_chann(inputs[i]),get_num(inputs[i])))
    end
    etc = CuDNNPoolingState(pooling_desc, inputs_desc, outputs_desc,
        padded_blobs, padded_blobs_diff)
  end
  return etc
end

function shutdown(sys::System{CuDNNBackend}, state::PoolingLayerState)
  map(destroy, state.blobs)
  map(destroy, state.blobs_diff)
  CuDNN.destroy_pooling_descriotpr(state.etc.pooling_desc)
  map(CuDNN.destroy_tensor4d_descriptor, state.etc.inputs_desc)
  map(CuDNN.destroy_tensor4d_descriptor, state.etc.outputs_desc)
  map(destroy, state.etc.padded_blobs)
  map(destroy, state.etc.padded_blobs_diff)
end

function forward(sys::System{CuDNNBackend}, state::PoolingLayerState, inputs::Vector{Blob})
  layer = state.layer
  if layer.pad[1] > 0 || layer.pad[2] > 0
    # TODO: remove this when CuDNN support pooling with padding
    for i = 1:length(inputs)
      input = inputs[i]
      padded_input = state.etc.padded_blobs[i]
      erase!(padded_input)

      dense2padded!(sys, padded_input, input, layer.pad)

      CuDNN.pooling_forward(sys.backend.cudnn_ctx, state.etc.pooling_desc,
          state.etc.inputs_desc[i], padded_input.ptr,
          state.etc.outputs_desc[i], state.blobs[i].ptr)
    end
  else
    for i = 1:length(inputs)
      CuDNN.pooling_forward(sys.backend.cudnn_ctx, state.etc.pooling_desc,
          state.etc.inputs_desc[i], inputs[i].ptr,
          state.etc.outputs_desc[i], state.blobs[i].ptr)
    end
  end
end

function backward(sys::System{CuDNNBackend}, state::PoolingLayerState, inputs::Vector{Blob}, diffs::Vector{Blob})
  layer = state.layer
  if layer.pad[1] > 0 || layer.pad[2] > 0
    # TODO: remove this when CuDNN support pooling with padding
    for i = 1:length(inputs)
      if isa(diffs[i], CuTensorBlob)
        CuDNN.pooling_backward(sys.backend.cudnn_ctx, state.etc.pooling_desc,
            state.etc.outputs_desc[i], state.blobs[i].ptr,
            state.etc.outputs_desc[i], state.blobs_diff[i].ptr,
            state.etc.inputs_desc[i], state.etc.padded_blobs[i].ptr,
            state.etc.inputs_desc[i], state.etc.padded_blobs_diff[i].ptr)

        padded2dense!(sys, diffs[i], state.etc.padded_blobs_diff[i], layer.pad)
      end
    end
  else
    for i = 1:length(inputs)
      if isa(diffs[i], CuTensorBlob)
        CuDNN.pooling_backward(sys.backend.cudnn_ctx, state.etc.pooling_desc,
            state.etc.outputs_desc[i], state.blobs[i].ptr,
            state.etc.outputs_desc[i], state.blobs_diff[i].ptr,
            state.etc.inputs_desc[i], inputs[i].ptr,
            state.etc.inputs_desc[i], diffs[i].ptr)
      end
    end
  end
end


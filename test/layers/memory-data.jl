function test_memory_data_layer(sys::System, T, eps)
  println("-- Testing Memory Data Layer on $(typeof(sys.backend)){$T}...")

  ############################################################
  # Prepare Data for Testing
  ############################################################
  batch_size = 6
  data_dim = (2,3,4)

  data = rand(T, data_dim..., 9)
  mean_data = rand(T, data_dim..., 1)
  mean_blob = make_blob(sys.backend, mean_data)

  ############################################################
  # Setup
  ############################################################

  # batch size is determined by
  layer = MemoryDataLayer(data = Array[data], tops = [:data], batch_size=batch_size,
      transformers=[(:data, DataTransformers.SubMean(mean_blob=mean_blob))])
  state = setup(sys, layer, Blob[], Blob[])

  data_idx = map(x->1:x, data_dim)
  layer_data = Array(eltype(data), tuple(data_dim..., batch_size))

  data_aug = cat(4, data, data)
  data_aug .-= mean_data
  forward(sys, state, Blob[])
  copy!(layer_data, state.blobs[1])
  @test all(-eps .< layer_data - data_aug[data_idx..., 1:1+batch_size-1] .< eps)
  @test state.epoch == 0

  forward(sys, state, Blob[])
  copy!(layer_data, state.blobs[1])
  @test all(-eps .< layer_data - data_aug[data_idx..., batch_size+1:2batch_size] .< eps)
  @test state.epoch == 1

  forward(sys, state, Blob[])
  copy!(layer_data, state.blobs[1])
  @test all(-eps .< layer_data - data_aug[data_idx..., 2batch_size+1:3batch_size] .< eps)
  @test state.epoch == 2

  shutdown(sys, state)
end
function test_memory_data_layer(sys::System)
  test_memory_data_layer(sys, Float32, 1e-5)
  test_memory_data_layer(sys, Float64, 1e-10)
end

if test_cpu
  test_memory_data_layer(sys_cpu)
end
if test_cudnn
  test_memory_data_layer(sys_cudnn)
end


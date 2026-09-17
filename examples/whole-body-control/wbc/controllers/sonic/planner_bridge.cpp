// Host simulation adapter around the actual pinned upstream planner code.
// Inference calls Python ONNX Runtime; planning/timeline algorithms stay C++.
#include <cstring>
#include <span>
#include <stdexcept>
#include "localmotion_kplanner.hpp"
#include "input_interface/streamed_motion_merger.hpp"

using Infer = int (*)(const float*, int, float, float, const float*, const float*, int,
                     float*, int*);
static thread_local std::string error_message;

class CallbackPlanner : public LocalMotionPlannerBase {
    Infer infer_;
    std::array<float, 144> context_{};
    std::array<float, 2304> output_{};
    std::array<float, 3> movement_{}, facing_{1,0,0};
    int mode_ = 0, frames_ = 0;
    float speed_ = -1, height_ = -1;
public:
    explicit CallbackPlanner(Infer infer) : LocalMotionPlannerBase([] {
        PlannerConfig c; c.version = 2; return c;
    }()), infer_(infer) {}
    bool InitializeSpecific() override { return true; }
    void RunInference() override {
        if (!infer_(context_.data(), mode_, speed_, height_, movement_.data(), facing_.data(),
                    current_random_seed_, output_.data(), &frames_))
            throw std::runtime_error("SONIC planner inference callback failed");
        if (frames_ < 2 || frames_ > 64) throw std::runtime_error("Invalid planner frame count");
    }
    void UpdateInputTensors(int mode, float speed, float height,
                           const std::array<float,3>& movement,
                           const std::array<float,3>& facing, int seed) override {
        mode_ = mode < GetValidModeValueRange() ? mode : 0;
        speed_ = speed; height_ = height; movement_ = movement; facing_ = facing;
        if (seed != -1) current_random_seed_ = seed;
    }
    float* GetContextBuffer() override { return context_.data(); }
    int32_t GetNumPredFrames() override { return frames_; }
    const float* GetMujocoQposBuffer() override { return output_.data(); }
    float* GetMovementDirectionValues() override { return movement_.data(); }
    float* GetFacingDirectionValues() override { return facing_.data(); }
    float GetTargetVelValue() override { return speed_; }
    float GetHeightValue() override { return height_; }
    int32_t GetRandomSeedValue() override { return current_random_seed_; }
    int32_t GetModeValue() override { return mode_; }
};

// These accessors adapt REAL simulated measurements to the methods used by
// G1Deploy::Planner/CurrentFrameAdvancement, without a DDS or hardware session.
struct SimMotor { double value = 0; double q() const { return value; } };
struct SimImu { std::array<float,4> value{1,0,0,0}; const auto& quaternion() const { return value; } };
struct LowState_ {
    std::array<SimMotor,29> motors;
    SimImu imu;
    const auto& motor_state() const { return motors; }
    const auto& imu_state() const { return imu; }
};

class Runtime {
public:
    OperatorState operator_state;
    std::unique_ptr<LocalMotionPlannerBase> planner_;
    std::shared_ptr<MotionSequence> planner_motion_ = std::make_shared<MotionSequence>();
    std::shared_ptr<const MotionSequence> current_motion_;
    int current_frame_ = 0, initial_encoder_mode_ = 0, saved_frame_for_observation_window_ = 46;
    std::mutex current_motion_mutex_;
    DataBuffer<LowState_> low_state_buffer_;
    DataBuffer<MovementState> movement_state_buffer_;
    MotionDataReader motion_reader_;
    MotionRecorder planner_motion_recorder_;
    bool enable_motion_recording_ = false, reinitialize_heading_ = false;
    std::ofstream* planner_motion_file_ = nullptr;
    double planner_dt_ = .1;
    StreamedMotionMerger stream_merger_;
    std::shared_ptr<MotionSequence> streamed_motion_;
    int streamed_frame_ = 0;

    // The following fields and two methods are copied mechanically from the
    // fingerprint-verified deployment source at build time, NOT rewritten.
    // OPERATOR_UPSTREAM_FIELDS
    // OPERATOR_UPSTREAM_METHODS

    explicit Runtime(Infer infer) : planner_(std::make_unique<CallbackPlanner>(infer)) {
        planner_motion_->ReserveCapacity(1500,29,1,1,0,0);
        current_motion_ = planner_motion_;
        movement_state_buffer_.SetData(MovementState(0,{0,0,0},{1,0,0},-1,-1));
    }
};

extern "C" {
const char* sonic_error() { return error_message.c_str(); }
void* sonic_create(Infer infer) {
    try { return new Runtime(infer); }
    catch (const std::exception& e) { error_message=e.what(); return nullptr; }
}
void sonic_destroy(void* ptr) { delete static_cast<Runtime*>(ptr); }
void sonic_measurements(void* ptr, const double* quaternion, const double* joints) {
    LowState_ state;
    for(int i=0;i<4;i++) state.imu.value[i]=quaternion[i];
    for(int i=0;i<29;i++) state.motors[i].value=joints[i];
    static_cast<Runtime*>(ptr)->low_state_buffer_.SetData(state);
}
void sonic_movement(void* ptr, int mode, const double* movement, const double* facing,
                    double speed, double height) {
    static_cast<Runtime*>(ptr)->movement_state_buffer_.SetData(MovementState(mode,
        {movement[0],movement[1],movement[2]}, {facing[0],facing[1],facing[2]}, speed,height));
}
int sonic_plan(void* ptr) {
    try {
        auto& r=*static_cast<Runtime*>(ptr);
        r.operator_state.play=true;
        r.planner_->planner_state_.enabled=true;
        r.Planner();
        if(!r.planner_->planner_state_.initialized) throw std::runtime_error("Official planner failed");
        return 1;
    } catch(const std::exception& e) { error_message=e.what(); return 0; }
}
int sonic_advance(void* ptr) {
    try {
        auto& r=*static_cast<Runtime*>(ptr);
        int result=r.CurrentFrameAdvancement();
        if(r.current_motion_==r.streamed_motion_) r.streamed_frame_=r.current_frame_;
        return result;
    }
    catch(const std::exception& e) { error_message=e.what(); return 0; }
}
int sonic_references(void* ptr, double* q, double* dq, double* rotation, double* position) {
    auto& r=*static_cast<Runtime*>(ptr);
    std::lock_guard<std::mutex> lock(r.current_motion_mutex_);
    auto motion=r.current_motion_;
    if(!motion || motion->timesteps<1) return 0;
    for(int i=0;i<10;i++) {
        int f=std::min(r.current_frame_+i*5,motion->timesteps-1);
        std::copy_n(motion->JointPositions(f),29,q+i*29);
        std::copy_n(motion->JointVelocities(f),29,dq+i*29);
        std::copy_n(motion->BodyQuaternions(f)[0].data(),4,rotation+i*4);
        std::copy_n(motion->BodyPositions(f)[0].data(),3,position+i*3);
    }
    return 1;
}
int sonic_frame(void* ptr) { return static_cast<Runtime*>(ptr)->current_frame_; }
int sonic_take_heading_reset(void* ptr) {
    auto& r=*static_cast<Runtime*>(ptr);
    bool reset=r.reinitialize_heading_; r.reinitialize_heading_=false; return reset;
}
void sonic_mode(void* ptr, int planner) {
    auto& r=*static_cast<Runtime*>(ptr);
    if(planner && !r.planner_->planner_state_.enabled) {
        r.planner_->planner_state_.initialized=false;
        r.planner_motion_->timesteps=0;
        r.current_frame_=0;
    }
    if(!planner && r.planner_->planner_state_.enabled) {
        r.stream_merger_.Reset(); r.streamed_motion_.reset(); r.streamed_frame_=0;
        // Keep the last valid reference while the official POSE streamer fills
        // its initial window. Switch only when an actual pose packet arrives.
    }
    r.planner_->planner_state_.enabled=planner;
    r.operator_state.play=true;
    r.saved_frame_for_observation_window_=planner ? 46 : 10;
}
int sonic_stream(void* ptr, int n, const int64_t* indices, const double* q,
                 const double* dq, const double* quat, const double* joints, const double* pose) {
    try {
        if(n<1 || n>128) throw std::runtime_error("Invalid streamed frame count");
        auto& r=*static_cast<Runtime*>(ptr);
        StreamedMotionMerger::IncomingData data;
        data.protocol_version=3; data.num_frames=n; data.num_joints=29;
        data.num_quat_bodies=1; data.num_smpl_joints=24; data.num_smpl_poses=21;
        data.frame_indices.assign(indices,indices+n);
        for(int f=0;f<n;f++) {
            data.joint_pos.emplace_back(q+29*f,q+29*(f+1));
            data.joint_vel.emplace_back(dq+29*f,dq+29*(f+1));
            data.body_quat.push_back({{quat[f*4],quat[f*4+1],quat[f*4+2],quat[f*4+3]}});
            std::vector<std::array<double,3>> j(24),p(21);
            for(int i=0;i<24;i++) std::copy_n(joints+f*72+i*3,3,j[i].data());
            for(int i=0;i<21;i++) std::copy_n(pose+f*63+i*3,3,p[i].data());
            data.smpl_joints.push_back(j); data.smpl_pose.push_back(p);
        }
        auto result=r.stream_merger_.MergeIncomingData(data,r.streamed_frame_);
        if(!result.motion) throw std::runtime_error("Official stream merge failed");
        r.streamed_frame_=result.did_catchup_reset ? 0 : std::max(0,r.streamed_frame_-result.frame_offset_adjustment);
        bool first=!r.streamed_motion_;
        r.streamed_motion_=result.motion;
        if(!r.planner_->planner_state_.enabled) {
            r.current_motion_=result.motion; r.current_frame_=r.streamed_frame_;
            if(first) r.reinitialize_heading_=true;
        }
        return 1;
    } catch(const std::exception& e) { error_message=e.what(); return 0; }
}
int sonic_pose_references(void* ptr, double* joints, double* quaternion, double* wrists) {
    auto& r=*static_cast<Runtime*>(ptr);
    std::lock_guard<std::mutex> lock(r.current_motion_mutex_);
    auto motion=r.current_motion_;
    if(!motion || motion->timesteps<1 || motion->GetNumSmplJoints()!=24) return 0;
    for(int i=0;i<10;i++) {
        int f=std::min(r.current_frame_+i,motion->timesteps-1);
        for(int j=0;j<24;j++) std::copy_n(motion->SmplJoints(f)[j].data(),3,joints+i*72+j*3);
        std::copy_n(motion->BodyQuaternions(f)[0].data(),4,quaternion+i*4);
        for(int j=0;j<6;j++) wrists[i*6+j]=motion->JointPositions(f)[23+j];
    }
    return 1;
}
}

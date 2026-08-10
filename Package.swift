// swift-tools-version: 5.9
import PackageDescription

/// The float-build source list for vendored libopus (from the release's
/// silk/celt/opus_sources.mk), plus our variadic-ctl shim. Arch-specific
/// intrinsics (celt/arm, celt/x86, silk/*/x86 …) are deliberately not
/// compiled — the plain C paths are portable and fast enough for one
/// voice stream.
let opusSources: [String] = {
    let silk = [
        "CNG", "code_signs", "init_decoder", "decode_core", "decode_frame",
        "decode_parameters", "decode_indices", "decode_pulses", "decoder_set_fs",
        "dec_API", "enc_API", "encode_indices", "encode_pulses", "gain_quant",
        "interpolate", "LP_variable_cutoff", "NLSF_decode", "NSQ", "NSQ_del_dec",
        "PLC", "shell_coder", "tables_gain", "tables_LTP", "tables_NLSF_CB_NB_MB",
        "tables_NLSF_CB_WB", "tables_other", "tables_pitch_lag",
        "tables_pulses_per_block", "VAD", "control_audio_bandwidth",
        "quant_LTP_gains", "VQ_WMat_EC", "HP_variable_cutoff", "NLSF_encode",
        "NLSF_VQ", "NLSF_unpack", "NLSF_del_dec_quant", "process_NLSFs",
        "stereo_LR_to_MS", "stereo_MS_to_LR", "check_control_input",
        "control_SNR", "init_encoder", "control_codec", "A2NLSF",
        "ana_filt_bank_1", "biquad_alt", "bwexpander_32", "bwexpander", "debug",
        "decode_pitch", "inner_prod_aligned", "lin2log", "log2lin",
        "LPC_analysis_filter", "LPC_inv_pred_gain", "table_LSF_cos", "NLSF2A",
        "NLSF_stabilize", "NLSF_VQ_weights_laroia", "pitch_est_tables",
        "resampler", "resampler_down2_3", "resampler_down2",
        "resampler_private_AR2", "resampler_private_down_FIR",
        "resampler_private_IIR_FIR", "resampler_private_up2_HQ", "resampler_rom",
        "sigm_Q15", "sort", "sum_sqr_shift", "stereo_decode_pred",
        "stereo_encode_pred", "stereo_find_predictor", "stereo_quant_pred",
        "LPC_fit",
    ].map { "silk/\($0).c" }
    let silkFloat = [
        "apply_sine_window_FLP", "corrMatrix_FLP", "encode_frame_FLP",
        "find_LPC_FLP", "find_LTP_FLP", "find_pitch_lags_FLP",
        "find_pred_coefs_FLP", "LPC_analysis_filter_FLP",
        "LTP_analysis_filter_FLP", "LTP_scale_ctrl_FLP",
        "noise_shape_analysis_FLP", "process_gains_FLP",
        "regularize_correlations_FLP", "residual_energy_FLP",
        "warped_autocorrelation_FLP", "wrappers_FLP", "autocorrelation_FLP",
        "burg_modified_FLP", "bwexpander_FLP", "energy_FLP",
        "inner_product_FLP", "k2a_FLP", "LPC_inv_pred_gain_FLP",
        "pitch_analysis_core_FLP", "scale_copy_vector_FLP", "scale_vector_FLP",
        "schur_FLP", "sort_FLP",
    ].map { "silk/float/\($0).c" }
    let celt = [
        "bands", "celt", "celt_encoder", "celt_decoder", "cwrs", "entcode",
        "entdec", "entenc", "kiss_fft", "laplace", "mathops", "mdct", "modes",
        "pitch", "celt_lpc", "quant_bands", "rate", "vq",
    ].map { "celt/\($0).c" }
    let opus = [
        "opus", "opus_decoder", "opus_encoder", "opus_multistream",
        "opus_multistream_decoder", "opus_multistream_encoder", "repacketizer",
        "opus_projection_decoder", "opus_projection_encoder", "mapping_matrix",
        "analysis", "mlp", "mlp_data",
    ].map { "src/\($0).c" }
    return silk + silkFloat + celt + opus + ["shim/copus_shim.c"]
}()

let package = Package(
    name: "Pager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "decode-log", targets: ["DecodeLog"]),
        .executable(name: "e2e", targets: ["E2E"]),
        .executable(name: "design-preview", targets: ["DesignPreview"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "PagerCore", path: "Sources/PagerCore"),
        .target(
            name: "COpus",
            path: "Vendor/opus",
            sources: opusSources,
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .headerSearchPath("src"),
                .define("OPUS_BUILD"),
                .define("VAR_ARRAYS", to: "1"),
                .define("HAVE_LRINT", to: "1"),
                .define("HAVE_LRINTF", to: "1"),
            ]),
        .target(name: "VoiceCore", dependencies: ["PagerCore", "COpus"], path: "Sources/VoiceCore"),
        .target(name: "PagerUI", dependencies: ["PagerCore"], path: "Sources/PagerUI"),
        .executableTarget(
            name: "Pager",
            dependencies: ["PagerCore", "PagerUI", "VoiceCore",
                           .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Pager"),
        .executableTarget(name: "DecodeLog", dependencies: ["PagerCore"], path: "Sources/DecodeLog"),
        .executableTarget(name: "E2E", dependencies: ["PagerCore"], path: "Sources/E2E"),
        .executableTarget(name: "DesignPreview", dependencies: ["PagerUI"], path: "Sources/DesignPreview"),
        .testTarget(name: "PagerCoreTests", dependencies: ["PagerCore"], path: "Tests/PagerCoreTests"),
        .testTarget(name: "VoiceCoreTests", dependencies: ["VoiceCore"], path: "Tests/VoiceCoreTests"),
        .testTarget(name: "PagerUITests", dependencies: ["PagerUI"], path: "Tests/PagerUITests"),
    ]
)

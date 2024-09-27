/*
See repkv.cu for details. This is the backward pass of repkv forward.
Block size 128 seems fastest on H100
*/

#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include <assert.h>
#include "common.h"

// cpu reference code
void repkv_backward_cpu(float* dinp, const float* dout,
                       const int B, const int T, const int Cout,
                       const int hd, const int qh, const int kh, const int vh) {

    assert(Cout == (hd * (3 * qh)));
    assert(kh == vh);
    int nrep = qh / kh; // number of times to replicate key/value vectors
    int Cin = hd * (qh + kh + vh); // output channels

    for (int b = 0; b < B; b++) {
        for (int t = 0; t < T; t++) {
            // seek to the input position dout[b,t,:]
            const float* x = dout + b * T * Cout + t * Cout;
            // seek to the output position out[b,t,:]
            float* y = dinp + b * T * Cin + t * Cin;
            // copy all the query vectors, no changes
            for (int i = 0; i < hd * qh; i++) { y[i] = x[i]; }
            x += hd * qh; // advance input pointer
            y += hd * qh; // advance output pointer
            // copy key vectors, and replicate them nrep times
            for (int h = 0; h < kh; h++) {
                for (int n = 0; n < nrep; n++) {
                    for (int i = 0; i < hd; i++) { y[i] += x[i]; }
                    x += hd; // advance input pointer
                }
                y += hd; // advance output pointer
            }
            // copy value vectors, and replicate them nrep times
            for (int h = 0; h < vh; h++) {
                for (int n = 0; n < nrep; n++) {
                    for (int i = 0; i < hd; i++) { y[i] += x[i]; }
                    x += hd; // advance input pointer
                }
                y += hd; // advance output pointer
            }
        }
    }
}

// kernels
__global__ void repkv_backward_kernel2(floatX* dinp, const floatX* dout,
                                int B, int N, int NH, int replicate_factor, int HD) {
    // we have a single tensor dout of shapae of (B, N 3 * NH * HD)
    // we want to reduce sum (for K and V) into  (B, N, (NH + 2*(NH/replicate_factor)) * HD)
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= B * N * 3 * NH * HD) { return;}
    int dinp_idx = idx; // keep backup

    int NKV = NH / replicate_factor;
    int nkv_factor = (replicate_factor + 2);   // replicate_factor is for (replicate_factor * NKV == NQ), 2 for K V

    // decode the dinp index
    int d = idx % HD;
    idx /= HD;
    int nkv = idx % NKV;
    idx /= NKV;
    int c = idx % nkv_factor;
    idx /= nkv_factor;
    int n = idx % N;
    int b = idx / N;

    int dout_idx;
    int nh_total = 3 * NH;
    // int nh_total = NH + 2 * (NH / replicate_factor);

    if (c >= 0 && c < nkv_factor - 2) {
        dout_idx = b * N * nh_total * HD + n * nh_total * HD + c * NKV * HD + nkv * HD + d;
        dinp[dinp_idx] = __ldcs(&dout[dout_idx]);
    // } else if (c == nkv_factor - 2) {
    //     // if (nkv % replicate_factor == 0) {
    //         float reduced_sum = 0;
    //         dout_idx = b * N * nh_total * HD + n * nh_total * HD + c * NKV * HD + nkv * HD + d;
    //         for (int i = 0; i < replicate_factor; i++) {
    //             reduced_sum += __ldcs(&dout[dout_idx+HD*i]);
    //         }
    //         dinp[dinp_idx] = reduced_sum;
    //     // }

    } else {
        // if (nkv % replicate_factor == 0) {
            float reduced_sum = 0;
            dout_idx = b * N * nh_total * HD + n * nh_total * HD + c * NKV * HD + nkv * HD + d;
            for (int i = 0; i < replicate_factor; i++) {
                reduced_sum += __ldcs(&dout[dout_idx+HD*i]);
            }
            dinp[dinp_idx] = reduced_sum;

        // }
    }
}

// kernels
__global__ void repkv_backward_kernel1(floatX* dinp, const floatX* dout,
                                int B, int N, int NH, int replicate_factor, int HD) {
    // we have a single tensor dout of shapae of (B, N 3 * NH * HD)
    // we want to reduce sum (for K and V) into  (B, N, (NH + 2*(NH/replicate_factor)) * HD)
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= B * N * 3 * NH * HD) { return;}
    int dout_idx = idx; // keep backup

    // decode the dout index
    int d = idx % HD;
    idx /= HD;
    int nh = idx % NH;
    idx /= NH;
    int c = idx % 3;
    idx /= 3;
    int n = idx % N;
    int b = idx / N;

    int dinp_idx;
    int nh_total = NH + 2 * (NH / replicate_factor);

    if (c == 0) {
        dinp_idx = b * N * nh_total * HD + n * nh_total * HD + 0 * NH * HD + nh * HD + d;
        dinp[dinp_idx] = __ldcs(&dout[dout_idx]);
    } else if (c == 1) {
        if (nh % replicate_factor == 0) {
            float reduced_sum = 0;
            for (int i = 0; i < replicate_factor; i++) {
                reduced_sum += __ldcs(&dout[dout_idx+HD*i]);
            }

            dinp_idx = b * N * nh_total * HD + n * nh_total * HD + 1 * NH * HD + (nh / replicate_factor) * HD + d;
            dinp[dinp_idx] = reduced_sum;
        }

    } else {
        if (nh % replicate_factor == 0) {
            float reduced_sum = 0;
            for (int i = 0; i < replicate_factor; i++) {
                reduced_sum += __ldcs(&dout[dout_idx+HD*i]);
            }
            dinp_idx = b * N * nh_total * HD + n * nh_total * HD + (NH * HD + (NH / replicate_factor) * HD) + (nh / replicate_factor) * HD + d;
            dinp[dinp_idx] = reduced_sum;
        }
    }
}

// kernel launchers
void repkv_backward2(floatX* dinp, const floatX* dout,
    const int B, const int T, const int NH, const int NH_KV, const int d, int block_size) {
    int total_threads = B * T * (NH + 2 * NH_KV) * d;
    int num_blocks = ceil_div(total_threads, block_size);
    int replicate_factor = NH / NH_KV;
    repkv_backward_kernel2<<<num_blocks, block_size>>>(dinp, dout, B, T, NH, replicate_factor, d);
    cudaCheck(cudaGetLastError());
}

// kernel launchers
void repkv_backward1(floatX* dinp, const floatX* dout,
    const int B, const int T, const int NH, const int NH_KV, const int d, int block_size) {
    int total_threads = B * T * (3 * NH) * d;
    int num_blocks = ceil_div(total_threads, block_size);
    int replicate_factor = NH / NH_KV;
    repkv_backward_kernel1<<<num_blocks, block_size>>>(dinp, dout, B, T, NH, replicate_factor, d);
    cudaCheck(cudaGetLastError());
}

// kernel dispatcher
void repkv_backward(int kernel_num,
                   floatX* dinp, const floatX* dout,
                   int B, int T, int NH, int NH_KV, int d,
                   int block_size) {
    switch (kernel_num) {
        case 1:
            repkv_backward1(dinp, dout, B, T, NH, NH_KV, d, block_size);
            break;
        case 2:
            repkv_backward2(dinp, dout, B, T, NH, NH_KV, d, block_size);
            break;
        default:
            printf("Invalid kernel number\n");
            exit(1);
    }
}
#ifdef DEBUG
static void log_mat(float *inp, int B, int T, int C, int hd, int qh, int kh, int vh, char *title)
{
    printf("%s -----\n", title);
    for (int b = 0; b < B; b++) {
        printf("batch : %d ", b);
        for (int t = 0; t < T; t++) {
            printf("t = %d\n", t);
            const float* x = inp + b * T * C + t * C;
            printf("Query\n");
            for (int h=0; h < qh; h++) {
                for (int i = 0; i < hd; i++) {
                    printf("%f ", x[i]);
                }
                x += hd; // advance input pointer
                printf("\n");
            }
            printf("Key\n");
            for (int h=0; h < kh; h++) {
                for (int i = 0; i < hd; i++) {
                    printf("%f ", x[i]);
                }
                x += hd; // advance input pointer
                printf("\n");
            }
            printf("Value\n");
            for (int h=0; h < vh; h++) {
                for (int i = 0; i < hd; i++) {
                    printf("%f ", x[i]);
                }
                x += hd; // advance input pointer
                printf("\n");
            }
        }
    }
    printf("\n");
}
#endif // DEBUG

// tester
int main(int argc, char **argv) {
    srand(0);
#ifdef DEBUG
    int B = 1;
    int T = 2;
    int hd = 2; // head dim
    int qh = 4; // num query heads
    int kh = 2; // num key heads
    int vh = 2; // num value heads
#else
    int B = 8;
    int T = 1024;
    int hd = 128; // head dim
    int qh = 32; // num query heads
    int kh = 8; // num key heads
    int vh = 8; // num value heads
#endif

    int deviceIdx = 0;
    cudaCheck(cudaSetDevice(deviceIdx));

    int Cout = hd * (qh * 3); // out, upstream channels
    int Cin = hd * (qh + kh + vh); // in, downstream channels

    // allocate (and fill) CPU memory
    float* dinp = (float*)malloc(B * T * Cin * sizeof(float));
    memset(dinp, 0, B * T * Cin * sizeof(float));
    float* dout = make_random_float(B * T * Cout * sizeof(float));

    // allocate GPU memory
    float* d_dinp;
    float* d_inp;
    float* d_dout;
    cudaCheck(cudaMalloc(&d_dinp, B * T * Cin * sizeof(float)));
    cudaCheck(cudaMalloc(&d_inp, B * T * Cin * sizeof(float)));
    cudaCheck(cudaMalloc(&d_dout, B * T * Cout * sizeof(float)));

    // read kernel_num from command line
    int kernel_num = 1;
    if (argc > 1) {
        kernel_num = atoi(argv[1]);
    }
    printf("Using kernel %d\n", kernel_num);

#ifdef DEBUG
    int nrep = qh/kh;
    log_mat(dout, B, T, Cout, hd, qh, nrep*kh, nrep*vh, "dout");
#endif // DEBUG

    // CPU reference calculate
    repkv_backward_cpu(dinp, dout, B, T, Cout, hd, qh, kh, vh);

#ifdef DEBUG
    log_mat(dinp, B, T, Cin, hd, qh, kh, vh, "dinp");
#endif // DEBUG

    // check the correctness of the kernel at all block sizes
    int block_sizes[] = {32, 64, 128, 256, 512, 1024};
    cudaCheck(cudaMemcpy(d_dout, dout, B * T * Cout * sizeof(float), cudaMemcpyHostToDevice));
    for (int j = 0; j < sizeof(block_sizes) / sizeof(int); j++) {
        int block_size = block_sizes[j];
        printf("Checking block size %d.\n", block_size);
        repkv_backward(kernel_num, d_dinp, d_dout, B, T, qh, kh, hd, block_size);
        validate_result(d_dinp, dinp, "out", B * T * Cin, 1e-5f);
    }
    printf("All results match. Starting benchmarks.\n\n");

    // now benchmark
    for (int j = 0; j < sizeof(block_sizes) / sizeof(int); j++) {
        int block_size = block_sizes[j];
        int repeat_times = 1000;
        float elapsed_time = benchmark_kernel(repeat_times, repkv_backward, kernel_num,
                                            d_dinp, d_dout, B, T, qh, kh, hd, block_size);
        printf("block_size %4d time %.4f ms\n", block_size, elapsed_time);
    }

    // free memory
    free(dinp);
    free(dout);
    cudaCheck(cudaFree(d_dinp));
    cudaCheck(cudaFree(d_inp));
    cudaCheck(cudaFree(d_dout));

    return 0;
}


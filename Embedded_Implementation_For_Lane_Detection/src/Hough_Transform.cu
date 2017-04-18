/*
*Adapted From "Fast Hough Trasform on GPU's"
*
*/
#include"hough.hpp"
#include"cuda_error_check.hpp"
bool debug_hough = false;
#define THREADS_X_HOUGH	32
#define THREADS_Y_HOUGH	4
#define PIXELS_PER_THREAD 16


void print_array(float *arr, int size)
{
	for(int i =0;i<size;i++)
	{
		cout<<*(arr + i)<<"\t";
	}

	cout<<endl;

}

void print_image(unsigned char *image, int height, int width)
{


	for(int i =0;i<height;i++)
	{
		for(int j =0;j<width;j++)
		{
			cout<<(int)*(image + i*width + j)<<"\t";

		}
	
		cout<<endl;
	}

}

/*__global__ void Hough(unsigned char const* const image, unsigned int const
		threshold, unsigned int* const houghspace_1, unsigned int* const houghspace_2)
{
	int const x = blockIdx.x*blockDim.x + threadIdx.x;
	int const y = blockIdx.y*blockDim.y + threadIdx.y;
	__shared__ float sh_m_array[THREADS_X_HOUGH*THREADS_Y_HOUGH];
	int const n = threadIdx.y*THREADS_X_HOUGH + threadIdx.x;

	//Debugging
	//printf("n value : %d \n", n);


	sh_m_array[n]  =  (n-((HS_ANGLES-1)/2.0f)) / (float)((HS_ANGLES-1)/2.0f);
	//printf("shared_array_value : %f \t at postion : %d with thread indexes x: \
	//		%d and \t y : %d \n",sh_m_array[n], n, threadIdx.x, threadIdx.y);
	__syncthreads();

	unsigned char pixel = image[y*IMG_WIDTH + x];
	if(pixel >= threshold)
	{
		for(int n = 0;n<HS_ANGLES;n++)
		{
			float const m = sh_m_array[n];
			int const b1 = x - (int)(y*m) + IMG_HEIGHT;
			int const b2 = y - (int)(x*m) + IMG_WIDTH;
		
			atomicAdd(&houghspace_1[n*HS_1_WIDTH+b1], 1);
			atomicAdd(&houghspace_2[n*HS_2_WIDTH+b2], 1);
		}
	}

	

}
*/

__device__ static int g_counter;
__device__ static int g_counter_lines;
extern __shared__ int shmem[];

__global__ void getNonzeroEdgepoints(unsigned char const* const image, unsigned int* const list)
{

	
	__shared__ unsigned int s_queues[4][32 * PIXELS_PER_THREAD];
	__shared__ int s_qsize[4];
	__shared__ int s_globStart[4];

	const int x = blockIdx.x * blockDim.x * PIXELS_PER_THREAD + threadIdx.x;
	const int y = blockIdx.y * blockDim.y + threadIdx.y;

	if(threadIdx.x == 0)
		s_qsize[threadIdx.y] = 0;
	__syncthreads();

	if(y < 224)
	{	
		const unsigned char* srcRow = image + y*IMG_WIDTH;
		for(int i = 0,xx = x; i<PIXELS_PER_THREAD && xx < 192;++i,xx +=
				blockDim.x)
		{
			if(srcRow[xx])
			{
				const unsigned int val = (y<<16)|xx;
				//Atomic
				const int qidx = atomicAdd(&s_qsize[threadIdx.y],1);
				s_queues[threadIdx.y][qidx] = val;


			}


		}

	}

	__syncthreads();

	if(threadIdx.x == 0 && threadIdx.y == 0 )
	{	
		int totalSize = 0;
		for(int i =0;i<blockDim.y;++i)
			{
				s_globStart[i] = totalSize;
				totalSize += s_qsize[i];	

			}
		
		const int global_Offset = atomicAdd(&g_counter, totalSize);
		for(int i  =0 ;i<blockDim.y;++i)
			s_globStart[i] += global_Offset;
	}

	__syncthreads();

	const int qsize = s_qsize[threadIdx.y];
	int gidx = s_globStart[threadIdx.y] +  threadIdx.x;
	for(int i = threadIdx.x; i<qsize; i+=blockDim.x, gidx +=blockDim.x)
	{
		list[gidx] = s_queues[threadIdx.y][i];

	}

}

__global__ void fillHoughSpace(unsigned int* const list, const int count, int*
		hough_space,const float irho, const float theta, const int numrho)
{

	int* smem = (int*)shmem;
	for(int i =threadIdx.x; i< numrho + 1;i+=blockDim.x)
		smem[i] = 0;
	__syncthreads();
	

	const int n = blockIdx.x;
	const float ang = n*theta;
	
	//printf("The angle value of n is %d \n", blockIdx.x);

	//printf("Angle Values : %f \n", ang);
	//printf("Inside Kernel");
	
	
	float sinVal;
	float cosVal;

	sincosf(ang, &sinVal, &cosVal);
	sinVal *= irho;
	cosVal *= irho;

	const int shift = (numrho -1)/2;

	for(int i  = threadIdx.x; i<count; i+= blockDim.x)
	{
		const unsigned int val = list[i];

		const int x = (val & 0xFFFF);
		const int y = (val >> 16) & 0xFFFF;
		int r = __float2int_rn(x*cosVal + y*sinVal);
		//printf("The value of x %d and the value of y %d : the value of r %d \n",x,y,r);
		r += shift;
		
		atomicAdd(&smem[r+1],1);
	}
	
	__syncthreads();

	int* hrow = hough_space + (n+1)*(numrho + 2);
	for(int i = threadIdx.x ;i< numrho + 1; i+=blockDim.x)
	{	
		//printf("value of shared_memory at %d is %d \n",i,smem[i]);
		hrow[i] = smem[i];
	}
	

}


__global__ void getLines(const int * hough_space, float2* lines, int* votes, const int
		maxLines, const float rho, const float theta, const int threshold, const
		int numrho, const int rhspace)
{
	
	const int r = blockIdx.x*blockDim.x + threadIdx.x;
	const int n = blockIdx.y*blockDim.y + threadIdx.y;
	
	

	if(r >=numrho || n >=rhspace -2)
	{
		return;
	}

	const int curVotes = *(hough_space + (n+1)*(numrho + 2)+ (r+1));

	if(curVotes > *(hough_space + n*(numrho+2) + (r-1)) && 
			curVotes > *(hough_space + n*(numrho + 2) + r) && 
			curVotes > *(hough_space + n*(numrho + 2)+(r+1)) && 
			curVotes > *(hough_space + n*(numrho + 2) + (r+2)) && 
			curVotes > *(hough_space + n*(numrho+2) + (r+3)) && 
			curVotes > *(hough_space + (n+1)*(numrho +2)+ r-1) && 
			curVotes > *(hough_space + (n+1)*(numrho + 2) + r) && 
			curVotes > *(hough_space +(n+1)*(numrho +2) + (r+2)) && 
			curVotes > *(hough_space +(n+1)*(numrho +2) + (r+3)) && 
			curVotes > *(hough_space +(n+2)*(numrho +2) + (r-1)) && 
			curVotes > *(hough_space + (n+2)*(numrho +2) + r) && 
			curVotes > *(hough_space + (n+2)*(numrho +2) + (r+1)) && 
			curVotes > *(hough_space + (n+2)*(numrho +2) + (r+2)) && 
			curVotes > *(hough_space + (n+2)*(numrho +2) + (r+3)) && curVotes > threshold)
	{
		const float radius = (r - (numrho -1)*0.5f)*rho;
		const float angle = n*theta;

		const int index = atomicAdd(&g_counter_lines,1);
		if(index < maxLines)
		{
			//printf("index Value - %d \n", index);
			//printf("Current Votes - %d \n", curVotes);
			//printf("radius %f and angle %f \n", radius, angle);
			//*(lines + index) = make_float2(radius, angle);
			(lines +  index)->x = radius;
			(lines + index)->y = angle;
			//printf("value of radius - %f and value of angle - %f and curVotes - %d \n ", (lines +index)->x,(lines + index)->y, curVotes);
			*(votes + index) = curVotes;

		}
		


	}




}

lin_votes* houghTransform(unsigned char const* const edges,const int numangle, const int numrho,float thetaStep, float rStep)
{
	/*	if(debug_hough)
		{
			cudaEvent_t start, stop;
			cudaEventCreate(&start);
			cudaEventCreate(&stop);
			cudaEventRecord(start,0);
		
		}
	*/
		/*Replace by maximum function using cuda*/
		const int threshold = 35;

		unsigned char* gimage;	
		unsigned int* glist; 

		void* counterPtr;
		cudaGetSymbolAddress(&counterPtr, g_counter);


		cudaMemset(counterPtr,0,sizeof(int));
		CudaCheckError();

		cudaFuncSetCacheConfig(getNonzeroEdgepoints, cudaFuncCachePreferShared);
			
		cudaMalloc((void**)&gimage, IMG_SIZE*sizeof(unsigned char));
		CudaCheckError();
	
		cudaMalloc((void**) &glist, IMG_SIZE*sizeof(unsigned int));
		CudaCheckError();
	
		/*Copy Image to GPU */	
	
		cudaMemcpy(gimage, edges, IMG_SIZE*sizeof(unsigned char),cudaMemcpyHostToDevice);
		CudaCheckError();
		
		dim3 dimBlock1(THREADS_X_HOUGH, THREADS_Y_HOUGH);
		dim3 dimGrid1(1, 56);
		getNonzeroEdgepoints<<<dimGrid1,dimBlock1>>>(gimage, glist);
		CudaCheckError();
		cudaDeviceSynchronize();

		int totalCount ;
		cudaMemcpy(&totalCount, counterPtr, sizeof(int),cudaMemcpyDeviceToHost);
		//cout<<"Total Count :"<<totalCount<<endl;

		if(debug_hough)
		{
			unsigned int* clist = (unsigned int*)malloc(totalCount*sizeof(unsigned int));
			cudaMemcpy(clist, glist, totalCount*sizeof(unsigned int),cudaMemcpyDeviceToHost);
			CudaCheckError();

			for(int i = 0; i< totalCount; i++)
			{	
				unsigned int const q_value = clist[i];
				cout<<"q_value : "<<q_value<<endl;
				const int x = (q_value & 0xFFFF);
				const int y = (q_value >> 16 ) & 0xFFFF;
				cout<<"coordinate ("<<x<<","<<y<<")"<<endl;
				cout<<"Value at coordinate :"<<(int)*(edges + y*IMG_WIDTH + x)<<endl;
			}

		
		}

		//Initialize hough_space
		int hough_size = (numangle + 2)*(numrho + 2);	
		int rhspace = numangle + 2;
		int colhspace = numrho + 2;
		
		//cout<<"rows : "<<rhspace<<endl;

		const dim3 block(1024);
		const dim3 grid(rhspace -2);

		//smemSize should be less than 49152 bytes

		size_t smemSize = (colhspace - 1)*sizeof(int);
		cout<<smemSize<<endl;

		thetaStep = thetaStep*(CV_PI/180);
	
		/*Allocate houghSpace on Gpu*/
		int *d_hough_space;

		cudaMalloc((void**)&d_hough_space,hough_size*sizeof(int));
		CudaCheckError();
	
		cudaMemset(d_hough_space, 0, hough_size*sizeof(int));
		CudaCheckError();
		
		fillHoughSpace<<<grid,block, smemSize>>>(glist, totalCount,d_hough_space, 1.0f/rStep, thetaStep, colhspace -2);
		CudaCheckError();

		cudaDeviceSynchronize();

	
		if(debug_hough)
		{
			int* hough_space = (int*)malloc(hough_size*sizeof(int));
			cudaMemcpy(hough_space, d_hough_space, hough_size*sizeof(int),cudaMemcpyDeviceToHost);
			CudaCheckError();
	
			for(int i =0;i<rhspace;i++)
			{	
				for(int j =0;j<colhspace;j++)
				{
					cout<<*(hough_space + i*colhspace +j)<<"\t";
	
				}
			
				cout<<endl;

			}
		}
	

		int maxLines = 10;
			
		float2* d_lines;
		int* d_votes;

		cudaMalloc((void**)&d_lines,maxLines*sizeof(float2));
		CudaCheckError();	

		cudaMalloc((void**)&d_votes, maxLines*sizeof(int));
		CudaCheckError();

		void *counterPtr_lines;			
		cudaGetSymbolAddress(&counterPtr_lines, g_counter_lines);
		
		cudaMemset(counterPtr_lines, 0, sizeof(int));
		CudaCheckError();

		const dim3 block_1(32,8);
		const int blocks_x = ((colhspace - 2 + block_1.x - 1)/(block_1.x));
		const int blocks_y = ((rhspace - 2 + block_1.y -1 )/(block_1.y));
		const dim3 grid_1(blocks_x, blocks_y);
			
		
		cudaFuncSetCacheConfig(getLines, cudaFuncCachePreferL1);
		getLines<<<grid_1, block_1>>>(d_hough_space, d_lines, d_votes, maxLines,rStep, thetaStep, threshold, colhspace -2, rhspace);
		CudaCheckError();	
		cudaDeviceSynchronize();

		int countlines;

		cudaMemcpy(&countlines, counterPtr_lines, sizeof(int),cudaMemcpyDeviceToHost);
		CudaCheckError();
	
		cout<<"totalCount of lines"<<countlines<<endl;	
		
		countlines = min(countlines, maxLines);
	
		float2* lines = (float2*)malloc(countlines*sizeof(float2)); 
		int* votes = (int*)malloc(countlines*sizeof(int));

		cudaMemcpy(lines, d_lines, countlines*sizeof(float2),cudaMemcpyDeviceToHost);
		CudaCheckError();	
		
		cudaMemcpy(votes, d_votes, countlines*sizeof(int),cudaMemcpyDeviceToHost);
		CudaCheckError();

		if(debug_hough)
		{
			Mat gray_image = imread("/home/nvidia/Lane_Detection/Test_Images/IPM_test_image_4.png",0);
		
			for(int i =0;i<countlines;i++)
			{
				float theta_line = (lines + i)->y;
				float rho = (lines + i)->x;
				
				cout<<"Rho - "<<rho<<"theta- "<<theta_line<<endl;
				cv::Point pt1, pt2;
	
				double a = cos(theta_line);
				double b = sin(theta_line);

				double x0 = a*rho;
				double y0 = b*rho;
	
				pt1.x = (int)(x0 + 400*(-b));
				pt1.y = (int)(y0 + 400*(a));
				pt2.x = (int)(x0 - 400*(-b));
				pt2.y = (int)(x0 - 400*(a));
				
				
				line(gray_image, pt1,pt2, (255,0,0),1);
				
			}
			imshow("IMage", gray_image);
			waitKey(0);

		}
	
		lin_votes* hough_lines = (lin_votes*)malloc(sizeof(lin_votes));
		hough_lines->lines = lines;
		hough_lines->countlines = countlines;

		
	
	/*	
		if(debug_hough)
		{	
			cudaEventRecord(stop,0);
			cudaEventSynchronize(stop);

			float elapsed = 0;
			cudaEventElapsedTime(&elapsed, start, stop);

			cout<<"Elapsed Time"<<elapsed;
		}
	
	*/

		return hough_lines;

}













/*
int main(int argc, char* argv[])
{

	Mat src_host = imread("/home/nvidia/Binary_test_image_for_cuda_ht_1.png",
			CV_8UC1);

	if(debug_hough)
	{
		cout<<"cols"<<src_host.cols<<endl;
		cout<<"rows"<<src_host.rows<<endl;
	}

	//cout<<src_host<<endl;
	//cout<<src_host.at<unsigned int>(48,34)<<endl;
	int count = 0;
	//cout<<src_host<<endl;
		
	count = countNonZero(src_host);
	if(debug_hough)
	{
		cout<<count<<endl;
	
	}

	Size size = src_host.size();
	int width = size.width;
	int height = size.height;

	if(debug_hough)
	{
		imshow("Result",src_host);
		waitKey(0);
		Size size = src_host.size();
		cout<<size<<endl;
		int width = size.width;
		int height = size.height;	
		cout<<width<<endl;
		cout<<height<<endl;	
	}
*/
	/*Convert array to uchar* (0-255)*/	
/*
	unsigned char *edge_image = src_host.data;
	if(debug_hough)
	{
		print_image(edge_image, height,width);	
	
	}
	//unsigned char* rowptr = edge_image + 2*IMG_WIDTH;
	//cout<<(int)*rowptr<<endl;

*/	
	/*unsigned int* houghspace_gpu_1 = (unsigned int*)malloc(HS_1_SIZE*sizeof(unsigned int));
	unsigned int* houghspace_gpu_2 = (unsigned int*)malloc(HS_2_SIZE*sizeof(unsigned int));
	
	unsigned int const threshold = 50;

	houghTransform(edge_image, threshold, houghspace_gpu_1, houghspace_gpu_2);	
	*/
/*		
	float rMin = 0;
	float rMax = (IMG_WIDTH + IMG_HEIGHT)*2 + 1;
	float rStep = 1.0;

	float thetaMin = 0;
	float thetaMax = 180;
	float thetaStep = 1;
	
	const int numangle = std::round((thetaMax - thetaMin)/thetaStep);
	const int numrho = std::round(rMax/rStep);

	if(debug_hough)
	{
		cout<<numangle<<endl;
		cout<<numrho<<endl;
	}

	float* r_values = new float[numrho];
	float* th_vaues = new float[numangle];
	
	int ri, thetai;
	float r, theta;

	for(r = rMin + rStep/2, ri=0;ri<numrho;ri++,r +=rStep)
	{
		r_values[ri] = r;

	}

	for(theta = thetaMin, thetai =0;thetai<numangle;thetai++,theta
			+=thetaStep)
	{
		th_vaues[thetai] =theta;

	}

	if(debug_hough)
	{
		print_array(r_values, numrho);
		print_array(th_vaues, numangle);
	}
	
	//int count = countNonZero(src_host);
	//cout<<count<<endl;	
	
	
	houghTransform(edge_image, numangle, numrho,thetaStep, rStep);
	
}
*/

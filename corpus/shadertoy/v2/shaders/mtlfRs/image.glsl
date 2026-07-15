const int N = 90;
float arr[N] = float[](17., 16., 19., 4., 32., 7., 9., 500., 21., 54., 33., 35., 47., 96., 64., 17., 16., 19., 4., 32., 7., 9., 500., 21.,  31., 1., -5., 7., 30., 22., 97., 4., 44., 79., 799., 9973., 64., -47., -8520., -9., 974., 34., 21., 54., 35., 47., 96., 64., 31., 1., -5., 7., 30., 22., 97., 4., 44., 79., 799., 9973., 64., -47., -8520., -9., 974., 21., 54., 35., 47., 96., 64., 31., 1., -5., 7., 30., 22., 97., 4., 44., 79., 799., 9973., 64., -47., -8520., -9., 974., 21., 54.);



// Bubble Sort
// https://www.geeksforgeeks.org/bubble-sort
void bubble_sort()
{
    bool swapped;
    float temp;
    for (int i = 0; i < N - 1; i++)
    {
        swapped = false;
        for (int j = 0; j < N - i - 1; j++)
        {
            if (arr[j] > arr[j + 1])
            {
                    // Swap
                arr[j] += arr[j + 1];
                arr[j + 1] = arr[j] - arr[j + 1];
                arr[j] -= arr[j + 1];
                swapped = true;
            }
        }

        // If no two elements were swapped by inner loop, then break.
        if (!swapped)
            break;
    }
}



// Insertion Sort
// https://betterprogramming.pub/5-basic-sorting-algorithms-you-must-know-9ef5b1f3949c
void insertion_sort()
{
    int i, j;
    float key;
    for (i = 1; i < N; i++)
    {
        key = arr[i];
        j = i - 1;

        /* Move elements of arr[0..i-1], that are greater than key, to one position ahead 
        of their current position */
        while (j >= 0 && arr[j] > key)
        {
            arr[j + 1] = arr[j];
            j--;
        }
        arr[j + 1] = key;
    }
}



// Selection Sort
// https://betterprogramming.pub/5-basic-sorting-algorithms-you-must-know-9ef5b1f3949c
void selection_sort()
{
    int i, j, min0;
    float temp;
    for (i = 0; i < N - 1; i++)
    {
        min0 = i;
        for (j = i + 1; j < N; j++) if (arr[j] < arr[min0])
            {
                min0 = j;
            }
        temp = arr[i];
        arr[i] = arr[min0];
        arr[min0] = temp;
    }
}



// Shaker Sort
// Suggested by Envy24
// https://www.shadertoy.com/view/stVfDV
void shaker_sort()
{
    for (int L = N - 1, E = 1, C = -1; L > E; --L, ++E)
    {
        while (++C < L)
        {
            if (arr[C] > arr[C + 1])
            {
                float A = arr[C];
                arr[C] = arr[C + 1];
                arr[C + 1] = A;
            }
        }

        while (--C >= E)
        {
            if (arr[C - 1] > arr[C])
            {
                float A = arr[C - 1];
                arr[C - 1] = arr[C];
                arr[C] = A;
            }
        }
    }
}



// Radix Sort
// Suggested by Envy24
// https://www.shadertoy.com/view/stVfDV
void radix_sort()
{
    const int max_num_of_digits = 3; // base 10 digits for max element value 255.
    const int base = 10;

    int temp[N];
    int digits_arr[10];
    int power = 1;
    float inv = 1. / 255.;

    for (int k = 0; k < max_num_of_digits; ++k)
    {
        for (int i = 0; i < 10; ++i)
        {
            digits_arr[i] = 0;
        }

        for (int i = 0; i < N; ++i)
        {
            int value = int(arr[i] * 255.);
            int digit = (value / power) % base;
            ++digits_arr[digit];
            temp[i] = value;
        }

        for (int i = 0; i < 9; ++i)
        {
            digits_arr[i + 1] += digits_arr[i];
        }

        for (int i = N - 1; i >= 0; --i)
        {
            float value = float(temp[i]) * inv;
            int digit = (temp[i] / power) % base;
            arr[--digits_arr[digit]] = value;
        }

        power *= base;
    }
}



// Quick Sort
// Suggested by Envy24
// https://www.shadertoy.com/view/stVfDV
void quick_sort()
{
    int pairs[2 * N], rw_offset = 0;

    pairs[rw_offset++] = 0;
    pairs[rw_offset++] = N - 1;

    while (rw_offset != 0)
    {
        /* Tony Hoare's partition. */
        int high = pairs[--rw_offset], low = pairs[--rw_offset];

        float pivot = (arr[low] + arr[high]) * 0.5;
        int i = low, j = high;

        for (int k = 0; k < N; ++k)
        {
            while (arr[i] < pivot)
            {
                ++i;
            }
            while (arr[j] > pivot)
            {
                --j;
            }

            if (i >= j)
            {
                break;
            }

            float t = arr[i];
            arr[i] = arr[j];
            arr[j] = t;
            ++i;
            --j;
        }
        /* Tony Hoare's partition. */

        if (low < j)
        {
            pairs[rw_offset++] = low;
            pairs[rw_offset++] = j;
        }
        if (j + 1 < high)
        {
            pairs[rw_offset++] = j + 1;
            pairs[rw_offset++] = high;
        }
    }
}



void mainImage(out vec4 frag_col, in vec2 frag_coord)
{
    // Sort arr in increasing order

    //bubble_sort();      // 10.6 fps
    //insertion_sort();   // 18.9 fps
    //selection_sort();   // 12.9 fps
    //shaker_sort();      // 12.3 fps
    quick_sort();       // 60.0 fps (maxed out, the real FPS may be higher)

    frag_col = vec4(arr[0]);
}

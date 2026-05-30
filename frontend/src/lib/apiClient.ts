import axios from 'axios';

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8080';

export const apiClient = axios.create({
    baseURL: API_BASE_URL,
    withCredentials: true, // Crucial for httpOnly cookies
});

// Restore token on app load (survives re-renders, cleared on tab close)
const savedToken = sessionStorage.getItem('auth_token');
if (savedToken) {
    apiClient.defaults.headers.common['Authorization'] = `Bearer ${savedToken}`;
}

// If cookie fails (cross-origin HTTP/HTTPS), fall back to Bearer token
export const setAuthToken = (token: string | null) => {
    if (token) {
        sessionStorage.setItem('auth_token', token);
        apiClient.defaults.headers.common['Authorization'] = `Bearer ${token}`;
    } else {
        sessionStorage.removeItem('auth_token');
        delete apiClient.defaults.headers.common['Authorization'];
    }
};
